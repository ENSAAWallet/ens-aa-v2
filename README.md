# TBA on ERC-4337
This project aims to enable token bound account (TBA) under the ERC-4337 protocol. 

## Challenges
Currently, ERC-4337 is a relatively mature account abstraction solution. At first glance, the developer only need to access the owner of the NFT during the ERC-4337 validation loop to implement token bound account.

However, in order to prevent bundlers from being attacked, ERC-4337 restricts the account behavior during the ERC-4337 validation loop. One of the constraints is that account validation can only access storage associated with the account. Due to the fact that the owner of the NFT is stored outside of the account, this approach becomes infeasible.

This project innovatively solves this problem and implements token bound account that meets the ERC-4337 specification.

## Handle cases
* transfer nft to other self accounts
* list nft on the market and unlist finally
* list nft on the market and finally deal
