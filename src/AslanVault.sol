// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IStrategy.sol";
import "./libraries/AslanErrors.sol";
import "./libraries/AslanEvents.sol";

/*//////////////////////////////////////////////////////////////
                        ASLAN VAULT
//////////////////////////////////////////////////////////////*/

contract AslanVault is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_STRATEGIES = 10;
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 3_000; // 30%
    uint256 public constant MAX_LIQUIDITY_BUFFER_BPS = 5_000; // 50%

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address[] public strategies;
    mapping(address => bool) public isActiveStrategy;

    uint256 public liquidityBufferBps = 1_000; // 10% default
    uint256 public performanceFeeBps = 1_000;  // 10% performance fee
    address public feeRecipient;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _admin,
        address _feeRecipient
    )
        ERC20(_name, _symbol)
        ERC4626(_asset)
    {
        if (_admin == address(0)) revert AslanErrors.ZeroAddress();
        if (_feeRecipient == address(0)) revert AslanErrors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(STRATEGIST_ROLE, _admin);

        feeRecipient = _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function addStrategy(address _strategy) external onlyRole(STRATEGIST_ROLE) {
        if (_strategy == address(0)) revert AslanErrors.ZeroAddress();
        if (isActiveStrategy[_strategy]) revert AslanErrors.StrategyAlreadyActive(_strategy);
        if (strategies.length >= MAX_STRATEGIES) revert AslanErrors.ExceedsMaxStrategies();
        if (IStrategy(_strategy).asset() != asset()) revert AslanErrors.StrategyAssetMismatch();

        strategies.push(_strategy);
        isActiveStrategy[_strategy] = true;

        emit AslanEvents.StrategyAdded(_strategy);
    }

    function removeStrategy(address _strategy) external onlyRole(STRATEGIST_ROLE) nonReentrant {
        if (!isActiveStrategy[_strategy]) revert AslanErrors.StrategyNotFound(_strategy);

        // Withdraw all capital from strategy before removing
        uint256 deployed = IStrategy(_strategy).totalDeployedAssets();
        if (deployed > 0) {
            uint256 withdrawn = IStrategy(_strategy).withdraw(deployed);
            emit AslanEvents.StrategyWithdraw(_strategy, withdrawn);
        }

        // Remove from array (swap with last element)
        uint256 len = strategies.length;
        for (uint256 i = 0; i < len; i++) {
            if (strategies[i] == _strategy) {
                strategies[i] = strategies[len - 1];
                strategies.pop();
                break;
            }
        }
        isActiveStrategy[_strategy] = false;

        emit AslanEvents.StrategyRemoved(_strategy);
    }

    function depositToStrategy(address _strategy, uint256 _amount) external onlyRole(STRATEGIST_ROLE) nonReentrant {
        if (!isActiveStrategy[_strategy]) revert AslanErrors.StrategyNotFound(_strategy);
        if (_amount == 0) revert AslanErrors.ZeroAmount();

        IERC20(asset()).safeTransfer(_strategy, _amount);
        IStrategy(_strategy).deposit(_amount);

        emit AslanEvents.StrategyDeposit(_strategy, _amount);
    }

    function withdrawFromStrategy(address _strategy, uint256 _amount) external onlyRole(STRATEGIST_ROLE) nonReentrant {
        if (!isActiveStrategy[_strategy]) revert AslanErrors.StrategyNotFound(_strategy);
        if (_amount == 0) revert AslanErrors.ZeroAmount();

        uint256 withdrawn = IStrategy(_strategy).withdraw(_amount);
        emit AslanEvents.StrategyWithdraw(_strategy, withdrawn);
    }

    function harvest(address _strategy) external onlyRole(STRATEGIST_ROLE) nonReentrant {
        if (!isActiveStrategy[_strategy]) revert AslanErrors.StrategyNotFound(_strategy);

        uint256 profit = IStrategy(_strategy).harvest();
        if (profit == 0) return;

        // Calculate fee in assets, then mint equivalent shares to feeRecipient
        uint256 feeAssets = (profit * performanceFeeBps) / MAX_BPS;
        if (feeAssets > 0) {
            uint256 feeShares = convertToShares(feeAssets);
            if (feeShares > 0) {
                _mint(feeRecipient, feeShares);
            }
        }

        emit AslanEvents.Harvest(_strategy, profit, feeAssets);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setLiquidityBuffer(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_bps > MAX_LIQUIDITY_BUFFER_BPS) revert AslanErrors.InvalidFee();
        liquidityBufferBps = _bps;
        emit AslanEvents.LiquidityBufferUpdated(_bps);
    }

    function setPerformanceFee(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_bps > MAX_PERFORMANCE_FEE_BPS) revert AslanErrors.InvalidFee();
        performanceFeeBps = _bps;
        emit AslanEvents.PerformanceFeeUpdated(_bps);
    }

    function setFeeRecipient(address _recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_recipient == address(0)) revert AslanErrors.ZeroAddress();
        feeRecipient = _recipient;
        emit AslanEvents.FeeRecipientUpdated(_recipient);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function emergencyWithdrawFromStrategy(address _strategy) external onlyRole(PAUSER_ROLE) nonReentrant {
        if (!isActiveStrategy[_strategy]) revert AslanErrors.StrategyNotFound(_strategy);
        uint256 withdrawn = IStrategy(_strategy).emergencyWithdraw();
        emit AslanEvents.StrategyWithdraw(_strategy, withdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint256 len = strategies.length;
        for (uint256 i = 0; i < len; i++) {
            total += IStrategy(strategies[i]).totalDeployedAssets();
        }
        return total;
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _ensureLiquidity(assets);
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        return super.redeem(shares, receiver, owner);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getStrategies() external view returns (address[] memory) {
        return strategies;
    }

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Pull assets from strategies if vault doesn't have enough liquidity
    function _ensureLiquidity(uint256 _needed) internal {
        uint256 available = IERC20(asset()).balanceOf(address(this));
        if (available >= _needed) return;

        uint256 deficit = _needed - available;
        uint256 len = strategies.length;

        for (uint256 i = 0; i < len && deficit > 0; i++) {
            uint256 deployed = IStrategy(strategies[i]).totalDeployedAssets();
            if (deployed == 0) continue;

            uint256 toWithdraw = deficit > deployed ? deployed : deficit;
            uint256 withdrawn = IStrategy(strategies[i]).withdraw(toWithdraw);
            emit AslanEvents.StrategyWithdraw(strategies[i], withdrawn);

            deficit = withdrawn >= deficit ? 0 : deficit - withdrawn;
        }

        available = IERC20(asset()).balanceOf(address(this));
        if (available < _needed) {
            revert AslanErrors.InsufficientLiquidity(_needed, available);
        }
    }
}
