// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal constant USER = address(0xBEEF);
    address internal constant SPENDER = address(0xCAFE);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedMetadataAndFullSupplyToActualDeployer() public {
        assertEq(token.name(), "Ember");
        assertEq(token.symbol(), "EMBR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        vm.prank(USER);
        LaunchToken another = new LaunchToken();
        assertEq(another.balanceOf(USER), another.totalSupply());
    }

    function testFuzz_transfersConserveSupplyAndChargeNoFee(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        uint256 supply = token.totalSupply();
        assertTrue(token.transfer(USER, amount));
        assertEq(token.balanceOf(USER), amount);
        assertEq(token.balanceOf(address(this)), supply - amount);
        assertEq(token.totalSupply(), supply);
        vm.prank(USER);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), supply);
    }

    function test_allowanceAndTransferFrom() public {
        token.approve(SPENDER, 10 ether);
        vm.prank(SPENDER);
        token.transferFrom(address(this), USER, 4 ether);
        assertEq(token.balanceOf(USER), 4 ether);
        assertEq(token.allowance(address(this), SPENDER), 6 ether);
        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 6 ether, 7 ether)
        );
        token.transferFrom(address(this), USER, 7 ether);
    }

    function test_invalidTransfersRevert() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, USER, 0, 1));
        token.transfer(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_neitherDeployerNorOutsiderHasMintAdminOrUpgradePaths() public {
        string[10] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory callData = abi.encodeWithSignature(selectors[i], USER, type(uint128).max);
            (bool deployerOK,) = address(token).call(callData);
            assertFalse(deployerOK, selectors[i]);
            vm.prank(USER);
            (bool outsiderOK,) = address(token).call(callData);
            assertFalse(outsiderOK, selectors[i]);
            assertEq(token.totalSupply(), 1_000_000_000 ether);
            assertEq(token.balanceOf(USER), 0);
        }
    }

    function test_deadAddressBurnIsTransferAndDoesNotReduceTotalSupply() public {
        address dead = 0x000000000000000000000000000000000000dEaD;
        token.transfer(dead, 123 ether);
        assertEq(token.balanceOf(dead), 123 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_noEscapeOpcodesInRuntime() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
