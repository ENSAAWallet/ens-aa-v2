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
    uint256 public constant MAX_PRIORITY_FEE = 3;
    uint256 public constant BASE_GAS = 35000;
    IEntryPoint private immutable _entryPoint;
    address public cacheOwner;

    constructor(IEntryPoint anEntryPoint) {
        _entryPoint = anEntryPoint;
    }

    function execute(
        address dest,
        uint256 value,
        bytes calldata func
    ) external onlyOwnerOrEntryPoint {
        _call(dest, value, func);
    }

    function updateOwnerAndCompensate(
        address payable recipient
    ) external returns (uint256 refund) {
        uint256 startGas = gasleft();
        require(recipient != address(0), "invalid recipient");
        if (updateOwner()) {
            refund = _compensate(startGas - gasleft(), recipient);
        }
    }

    function updateOwner() public returns (bool) {
        address currentOwner = owner();
        if (cacheOwner != currentOwner) {
            cacheOwner = currentOwner;
            return true;
        }
        return false;
    }

    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
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
                    ? 0
                    : SIG_VALIDATION_FAILED;
        }
        return
            cacheOwner == hash.recover(userOp.signature)
                ? 0
                : SIG_VALIDATION_FAILED;
    }

    function _compensate(
        uint256 gasUsed,
        address payable recipient
    ) internal returns (uint256 refund) {
        uint256 maxGasPrice = block.basefee + MAX_PRIORITY_FEE;
        uint256 gasPrice = maxGasPrice > tx.gasprice
            ? tx.gasprice
            : maxGasPrice;
        uint256 maxRefund = (gasUsed + BASE_GAS) * gasPrice;
        refund = address(this).balance > maxRefund
            ? maxRefund
            : address(this).balance;
        if (refund != 0) {
            (bool success, ) = recipient.call{value: refund}("");
            if (!success) {
                refund = 0;
            }
        }
    }
}
