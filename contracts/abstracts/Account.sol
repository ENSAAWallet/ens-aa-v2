// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {SimpleERC6551Account} from "@erc6551/examples/simple/SimpleERC6551Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";

abstract contract Account is SimpleERC6551Account, BaseAccount {
    uint256 internal constant SIG_VALIDATION_SUCCEEDED = 0;
    modifier onlyEntryPointOrOwner() virtual {
        require(
            msg.sender == owner() || msg.sender == address(entryPoint()),
            "Not token owner or entryPoint"
        );
        _;
    }

    /**
     * check current account deposit in the entryPoint
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    /**
     * deposit more funds for this account in the entryPoint
     */
    function addDeposit() public payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    /**
     * withdraw value from the account's deposit
     * @param withdrawAddress target to send to
     * @param amount to withdraw
     */
    function withdrawDepositTo(
        address payable withdrawAddress,
        uint256 amount
    ) public onlyEntryPointOrOwner {
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _callBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata data
    ) internal {
        require(
            dest.length == data.length && dest.length == value.length,
            "wrong array lengths"
        );
        for (uint256 i = 0; i < dest.length; i++) {
            _call(dest[i], 0, data[i]);
        }
    }
}
