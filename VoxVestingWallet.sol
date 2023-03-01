// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/finance/VestingWallet.sol";

/*
    VOX FINANCE 2.0

    Website: https://vox.finance
    Twitter: https://twitter.com/RealVoxFinance
    Telegram: https://t.me/VoxFinance
 */

contract VoxVestingWallet is VestingWallet {
    constructor(address beneficiary, uint64 startTimestamp) 
        VestingWallet(beneficiary, startTimestamp, 31536000) {}
}