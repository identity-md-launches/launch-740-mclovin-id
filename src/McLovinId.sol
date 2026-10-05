// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title McLovin.id (MCLOVIN)
/// @notice A fixed-supply ERC-20. The entire supply of 1,000,000,000 MCLOVIN (18 decimals) is minted
/// once, in the constructor, to the deployer. There is no owner, no further minting, no pause,
/// no blocklist, no fee and no burn hook: every transfer moves exactly the amount requested.
/// @dev In a launch through ProjectFactory.launchCustom the deployer is the factory, which then
/// distributes the supply according to the launch manifest. The constructor takes no arguments so
/// the creation code is identical wherever it is deployed and the CREATE2 address depends only on
/// the salt and the deployer.
contract McLovinId is ERC20 {
    /// @notice Whole-token supply before scaling by `decimals()`.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The full supply in minor units: 1,000,000,000 * 10 ** 18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** 18;

    /// @notice Mints the whole supply to `msg.sender`.
    constructor() ERC20("McLovin.id", "MCLOVIN") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
