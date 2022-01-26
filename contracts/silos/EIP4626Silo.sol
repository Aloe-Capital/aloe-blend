// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "contracts/interfaces/ISilo.sol";

interface IEIP4626 {
    /// @notice Mints `shares` amount of vault tokens to `to` by depositing exactly `value` underlying tokens.
    function deposit(address to, uint256 value) external returns (uint256 shares);

    /// @notice Burns `shares` vault tokens from `from`, withdrawing exactly `value` underlying tokens to `to`.
    function withdraw(
        address from,
        address to,
        uint256 value
    ) external returns (uint256 shares);

    /// @notice Returns the address of the token the vault uses for accounting, depositing, and withdrawing.
    function underlying() external view returns (address);

    /// Returns the value in underlying terms of the vault tokens held by `owner`. Equivalent to `previewRedeem(balanceOf(owner))`.
    function balanceOfUnderlying(address owner) external view returns (uint256);
}

contract EIP4626Silo is ISilo {
    /// @inheritdoc ISilo
    string public name;

    IEIP4626 public immutable vault;

    address public immutable underlying;

    constructor(IEIP4626 _vault) {
        vault = _vault;
        underlying = _vault.underlying();

        // ex: EIP4626 (fDAI) DAI Silo
        name = string(
            abi.encodePacked(
                "EIP4626 (",
                IERC20Metadata(address(vault)).symbol(),
                ") ",
                IERC20Metadata(underlying).symbol(),
                " Silo"
            )
        );
    }

    /// @inheritdoc ISilo
    function poke() external override {}

    /// @inheritdoc ISilo
    function deposit(uint256 amount) external override {
        if (amount == 0) return;
        _approve(underlying, address(vault), amount);
        vault.deposit(address(this), amount);
    }

    /// @inheritdoc ISilo
    function withdraw(uint256 amount) external override {
        if (amount == 0) return;
        vault.withdraw(address(this), address(this), amount);
    }

    /// @inheritdoc ISilo
    function balanceOf(address account) external view override returns (uint256 balance) {
        balance = vault.balanceOfUnderlying(account);
    }

    /// @inheritdoc ISilo
    function shouldAllowRemovalOf(address token) external view override returns (bool shouldAllow) {
        shouldAllow = token != address(vault);
    }

    function _approve(
        address token,
        address spender,
        uint256 amount
    ) private {
        // 200 gas to read uint256
        if (IERC20(token).allowance(address(this), spender) < amount) {
            // 20000 gas to write uint256 if changing from zero to non-zero
            // 5000  gas to write uint256 if changing from non-zero to non-zero
            IERC20(token).approve(spender, type(uint256).max);
        }
    }
}
