// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BuybackBurnHook} from "../../src/BuybackBurnHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Models an adversarial token, never deployed as EMBR.
contract ReentrantToken is ERC20 {
    BuybackBurnHook public hook;
    PoolKey private key;
    bool public rejectBurn;
    uint256 public attempts;
    bytes4 public rejection;

    constructor() ERC20("Adversarial", "ADV") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function configure(BuybackBurnHook hook_, PoolKey memory key_, bool reject) external {
        hook = hook_;
        key = key_;
        rejectBurn = reject;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == 0x000000000000000000000000000000000000dEaD && address(hook) != address(0)) {
            require(!rejectBurn, "burn transfer rejected");
            ++attempts;
            (bool success, bytes memory reason) = address(hook).call(abi.encodeCall(hook.buyback, (key)));
            require(!success, "reentry succeeded");
            rejection = bytes4(reason);
        }
    }
}
