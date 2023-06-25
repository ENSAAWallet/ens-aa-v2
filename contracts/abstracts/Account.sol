// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {Pausable} from "openzeppelin-contracts/security/Pausable.sol";

import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "openzeppelin-contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";

import {IERC6551Account} from "@erc6551/interfaces/IERC6551Account.sol";
import {ERC6551AccountLib} from "@erc6551/lib/ERC6551AccountLib.sol";

abstract contract Account is
    IERC165,
    IERC1271,
    IERC6551Account,
    Pausable,
    BaseAccount
{
    uint256 internal constant SIG_VALIDATION_SUCCEEDED = 0;
    address public cacheOwner;
    uint256 public nonce;

    receive() external payable {}

    modifier onlyEntryPointOrOwner() virtual {
        _requireNotPaused();
        if (msg.sender == address(entryPoint())) {
            // invoked by cacheOwner
        } else if (msg.sender == owner()) {
            // invoked by realOwner
            ++nonce;
        } else {
            revert("Not token owner or entryPoint");
        }
        _;
    }

    function token() external view returns (uint256, address, uint256) {
        return ERC6551AccountLib.token();
    }

    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = this
            .token();
        if (chainId != block.chainid) return address(0);

        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return (interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC6551Account).interfaceId);
    }

    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view returns (bytes4 magicValue) {
        _requireNotPaused();
        bool isValid = SignatureChecker.isValidSignatureNow(
            owner(),
            hash,
            signature
        );
        if (isValid) {
            return IERC1271.isValidSignature.selector;
        }
        return "";
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

    function _call(
        address to,
        uint256 value,
        bytes calldata data
    ) internal returns (bytes memory result) {
        emit TransactionExecuted(to, value, data);

        bool success;
        (success, result) = to.call{value: value}(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _callBatch(
        address[] calldata to,
        uint256[] calldata value,
        bytes[] calldata data
    ) internal {
        require(
            to.length == data.length && to.length == value.length,
            "wrong array lengths"
        );
        for (uint256 i = 0; i < to.length; i++) {
            _call(to[i], 0, data[i]);
        }
    }
}
