// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {IERC1271} from "openzeppelin-contracts/interfaces/IERC1271.sol";
import {IERC6551Account} from "@erc6551/interfaces/IERC6551Account.sol";

interface ITBAccount is IERC165, IERC1271, IERC6551Account {
    event OwnerUpdated(address indexed newOwner, address indexed cacheOwner);
    event Refund(address indexed recipient, uint256 profit);

    function executeBatch(
        address[] calldata to,
        uint256[] calldata value,
        bytes[] calldata data
    ) external payable;

    /// @notice must call `pause` before list the nft
    function pause() external;

    /// @notice anyone can call `syncOwner` to sync owner and unpause
    function syncOwner()
        external
        returns (bool isUpdated, address currentOwner);

    /// @notice anyone can call `syncOwnerAndRefund` to sync owner, unpause and get refund
    /// @notice make sure msg.sender is profitable and owner is updated
    function syncOwnerAndRefund(
        address payable recipient
    ) external returns (address currentOwner, uint256 profit);
}
