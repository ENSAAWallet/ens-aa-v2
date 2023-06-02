// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {UserOperation, UserOperationLib} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Account} from "./abstracts/Account.sol";

contract TBAccount is Account {
    using ECDSA for bytes32;
    using UserOperationLib for UserOperation;

    // `immutable` to prevent attacker changing those configurations.

    // prevent invoking `updateOwnerAndCompensate` with unreasonable priorityFeePerGas
    // e.g. 4 gwei
    uint256 public immutable maxPriorityFeePerGasForSync;
    // prevent invoking `updateOwnerAndCompensate` with unreasonable maxFeePerGas
    // e.g. 80 gwei
    uint256 public immutable maxFeePerGasForSync;
    // prevent invoking `updateOwnerAndCompensate` with unreasonable maxPreVerficationGas through ERC-4337 workflow
    // e.g. 50000 * 1.2
    uint256 public immutable maxPreVerficationGasForSync;
    // estimate the gas usage of `updateOwnerAndCompensate` (should > real gas usage)
    // e.g. 35000
    uint256 public immutable syncGasCost;
    // reward recipent if it help update cacheOwner to currentOwner in `updateOwnerAndCompensate`
    // e.g. 0.0005 ether
    uint256 public immutable syncReward;

    IEntryPoint private immutable _entryPoint;
    address public cacheOwner;

    event SyncOwner(address indexed newOwner, address indexed cacheOwner);
    event SyncRefund(
        address indexed recipient,
        bool indexed success,
        uint256 amount
    );
    event SkipExecution();

    modifier onlyEntryPointOrOwner() override {
        (bool isUpdated, address currentOwner, ) = updateOwnerAndCompensate(
            payable(cacheOwner)
        );

        if (
            msg.sender == currentOwner ||
            (msg.sender == address(entryPoint()) && !isUpdated)
        ) {
            // method is invoked by the current owner
            _;
        } else {
            emit SkipExecution();
        }
    }

    constructor(
        IEntryPoint anEntryPoint,
        uint256 _maxPriorityFeePerGasForSync,
        uint256 _maxFeePerGasForSync,
        uint256 _maxPreVerficationGasForSync,
        uint256 _syncGasCost,
        uint256 _syncReward
    ) {
        _entryPoint = anEntryPoint;
        maxPriorityFeePerGasForSync = _maxPriorityFeePerGasForSync;
        maxFeePerGasForSync = _maxFeePerGasForSync;
        maxPreVerficationGasForSync = _maxPreVerficationGasForSync;
        syncGasCost = _syncGasCost;
        syncReward = _syncReward;
    }

    function execute(
        address dest,
        uint256 value,
        bytes calldata func
    ) external onlyEntryPointOrOwner {
        _call(dest, value, func);
    }

    function executeBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata data
    ) external onlyEntryPointOrOwner {
        _callBatch(dest, value, data);
    }

    function updateOwnerAndCompensate(
        address payable recipient
    ) public returns (bool isUpdated, address currentOwner, uint256 refund) {
        (isUpdated, currentOwner) = updateOwner();
        if (isUpdated && recipient != address(0)) {
            refund = _compensate(recipient);
        }
    }

    function updateOwner()
        public
        returns (bool isUpdated, address currentOwner)
    {
        currentOwner = owner();
        _cacheOwner = cacheOwner;
        if (_cacheOwner != currentOwner) {
            cacheOwner = _cacheOwner;
            isUpdated = true;
        }
        emit SyncOwner(currentOwner, cacheOwner);
    }

    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external virtual override returns (uint256 validationData) {
        _requireFromEntryPoint();

        require(
            userOp.maxFeePerGas < maxFeePerGasForSync,
            "maxFeePerGas too high (should <= `maxFeePerGasForSync`)"
        );
        require(
            userOp.maxPriorityFeePerGas < maxPriorityFeePerGasForSync,
            "maxPriorityFeePerGas too high (should <= `maxPriorityFeePerGasForSync`)"
        );
        require(
            userOp.callGasLimit > syncGasCost,
            "callGasLimit too low (should > `syncGasCost`)"
        );
        require(
            userOp.preVerificationGas < maxPreVerficationGasForSync,
            "preVerificationGas too high (should > `maxPreVerficationGasForSync`)"
        );
        validationData = userOp.nonce == 0
            ? SIG_VALIDATION_SUCCEEDED
            : _validateSignature(userOp, userOpHash);
        _validateNonce(userOp.nonce);
        _payPrefund(missingAccountFunds);
    }

    function _validateSignature(
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) internal virtual override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        if (cacheOwner.code.length > 0) {
            return
                IERC1271(cacheOwner).isValidSignature(hash, userOp.signature) ==
                    IERC1271.isValidSignature.selector
                    ? SIG_VALIDATION_SUCCEEDED
                    : SIG_VALIDATION_FAILED;
        }
        return
            cacheOwner == hash.recover(userOp.signature)
                ? SIG_VALIDATION_SUCCEEDED
                : SIG_VALIDATION_FAILED;
    }

    function _compensate(
        address payable recipient
    ) internal returns (uint256 refund) {
        uint256 maxRefund = syncReward;
        // if msg.sender is entryPoint, the gas fee is paied by TBAccount itself.
        if (msg.sender != address(entryPoint())) {
            uint256 gasPrice = _min(
                block.basefee + maxPriorityFeePerGasForSync,
                tx.gasprice,
                maxFeePerGasForSync
            );

            maxRefund += syncGasCost * gasPrice;
        }
        refund = _min(address(this).balance, maxRefund);
        if (refund != 0) {
            (bool success, ) = recipient.call{value: refund}("");
            if (!success) {
                refund = 0;
            }
        }
        emit SyncRefund(recipient, refund == 0, refund);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? b : a;
    }

    function _min(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        return _min(_min(a, b), c);
    }
}
