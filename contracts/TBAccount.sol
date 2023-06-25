// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {UserOperation, UserOperationLib} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {Account} from "./abstracts/Account.sol";

import {ITBAccount} from "./interfaces/ITBAccount.sol";

contract TBAccount is ITBAccount, Account {
    using ECDSA for bytes32;
    using UserOperationLib for UserOperation;
    // estimate the gas usage of `syncOwner` (should > real gas usage)
    // e.g. 35000
    uint256 public immutable syncGasCost;
    // estimate the gas usage of `refund` (should > real gas usage)
    // e.g. 1000 + 2300
    uint256 public immutable refundGasCost;
    // reward recipent if it help update cacheOwner to currentOwner in `syncOwnerAndRefund`
    // e.g. 0.0005 ether
    uint256 public immutable syncRefund;
    // prefund to call `syncOwner` through entryPoint
    // e.g. 0.0010 ether
    uint256 public immutable syncPrefund;

    IEntryPoint private immutable _entryPoint;

    constructor(
        IEntryPoint anEntryPoint,
        uint256 _syncGasCost,
        uint256 _refundGasCost,
        uint256 _syncRefund,
        uint256 _syncPrefund
    ) {
        _entryPoint = anEntryPoint;
        syncGasCost = _syncGasCost;
        refundGasCost = _refundGasCost;
        syncRefund = _syncRefund;
        syncPrefund = _syncPrefund;
    }

    function executeCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external payable onlyEntryPointOrOwner returns (bytes memory result) {
        result = _call(to, value, data);
    }

    function executeBatch(
        address[] calldata to,
        uint256[] calldata value,
        bytes[] calldata data
    ) external payable onlyEntryPointOrOwner {
        _callBatch(to, value, data);
    }

    // must call `pause` before list the nft
    // anyone can call `syncOwner` to unpause
    function pause() public onlyEntryPointOrOwner {
        _pause();
    }

    function syncOwner() public returns (bool isUpdated, address currentOwner) {
        currentOwner = owner();
        address _cacheOwner = cacheOwner;
        if (_cacheOwner != currentOwner) {
            cacheOwner = _cacheOwner;
            isUpdated = true;
            emit OwnerUpdated(currentOwner, cacheOwner);
        }

        // only unpase when owner equals to cacheOwner
        if (paused()) {
            _unpause();
        }
    }

    function syncOwnerAndRefund(
        address payable recipient
    ) public returns (address currentOwner, uint256 profit) {
        // if profit < 0, tx will revert
        profit = syncRefund - tx.gasprice * (syncGasCost + refundGasCost);

        (bool isUpdated, address _currentOwner) = syncOwner();
        require(isUpdated, "owner should be updated");

        if (recipient == address(0)) {
            recipient = payable(msg.sender);
        }

        // 2300 gas
        recipient.transfer(syncRefund);
        emit Refund(recipient, profit);

        currentOwner = _currentOwner;
    }

    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external virtual override whenNotPaused returns (uint256 validationData) {
        _requireFromEntryPoint();

        if (userOp.nonce == 0 || paused()) {
            require(
                keccak256(userOp.callData) ==
                    keccak256(abi.encodeCall(this.syncOwner, ())),
                "only allow to syncOwner when init or unpause"
            );
            require(
                userOp.callGasLimit >= syncGasCost,
                "not enought callCasLimit to syncOwner"
            );
            require(
                _getRequiredPrefund(userOp) <= syncPrefund,
                "too much required prefund when init"
            );
        }

        validationData = _validateSignature(userOp, userOpHash);

        _payPrefund(missingAccountFunds);
    }

    function _validateSignature(
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) internal virtual override returns (uint256 validationData) {
        return
            validationData = userOp.nonce == 0 ||
                SignatureChecker.isValidSignatureNow(
                    cacheOwner,
                    userOpHash.toEthSignedMessageHash(),
                    userOp.signature
                )
                ? SIG_VALIDATION_SUCCEEDED
                : SIG_VALIDATION_FAILED;
    }

    function _getRequiredPrefund(
        UserOperation calldata userOp
    ) internal pure returns (uint256 requiredPrefund) {
        unchecked {
            //when using a Paymaster, the verificationGasLimit is used also to as a limit for the postOp call.
            // our security model might call postOp eventually twice
            uint256 mul = userOp.paymasterAndData.length != 0 ? 3 : 1;
            uint256 requiredGas = userOp.callGasLimit +
                userOp.verificationGasLimit *
                mul +
                userOp.preVerificationGas;

            requiredPrefund = requiredGas * userOp.maxFeePerGas;
        }
    }
}
