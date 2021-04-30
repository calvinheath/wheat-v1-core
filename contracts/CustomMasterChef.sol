// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.6.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import { MintableToken } from "./MintableToken.sol";
import { MintableStakeToken } from "./MintableStakeToken.sol";
import { WhitelistGuard } from "./WhitelistGuard.sol";

// MasterChef is the master of Cake. He can make Cake and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CAKE is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract CustomMasterChef is WhitelistGuard
{
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	// Info of each user.
	struct UserInfo {
		uint256 amount;     // How many LP tokens the user has provided.
		uint256 rewardDebt; // Reward debt. See explanation below.
		//
		// We do some fancy math here. Basically, any point in time, the amount of CAKEs
		// entitled to a user but is pending to be distributed is:
		//
		//   pending reward = (user.amount * pool.accCakePerShare) - user.rewardDebt
		//
		// Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
		//   1. The pool's `accCakePerShare` (and `lastRewardBlock`) gets updated.
		//   2. User receives the pending reward sent to his/her address.
		//   3. User's `amount` gets updated.
		//   4. User's `rewardDebt` gets updated.
	}

	// Info of each pool.
	struct PoolInfo {
		IERC20 lpToken;           // Address of LP token contract.
		uint256 allocPoint;       // How many allocation points assigned to this pool. CAKEs to distribute per block.
		uint256 lastRewardBlock;  // Last block number that CAKEs distribution occurs.
		uint256 accCakePerShare; // Accumulated CAKEs per share, times 1e12. See below.
	}

	// The CAKE TOKEN!
	MintableToken public immutable cake;
	// The SYRUP TOKEN!
	MintableStakeToken public immutable syrup;
	// CAKE tokens created per block.
	uint256 public cakePerBlock;
	// Bonus muliplier for early cake makers.
	uint256 public BONUS_MULTIPLIER = 1;

	// Info of each pool.
	PoolInfo[] public poolInfo;
	// Info of each user that stakes LP tokens.
	mapping (uint256 => mapping (address => UserInfo)) public userInfo;
	// Total allocation points. Must be the sum of all allocation points in all pools.
	uint256 public totalAllocPoint = 0;
	// The block number when CAKE mining starts.
	uint256 public immutable startBlock;

	event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
	event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

	constructor (address _cake, address _syrup, uint256 _cakePerBlock, uint256 _startBlock)
		public
	{
		cake = MintableToken(_cake);
		syrup = MintableStakeToken(_syrup);
		cakePerBlock = _cakePerBlock;
		startBlock = _startBlock;

		// staking pool
		poolInfo.push(PoolInfo({
			lpToken: IERC20(_cake),
			allocPoint: 1000,
			lastRewardBlock: _startBlock,
			accCakePerShare: 0
		}));

		totalAllocPoint = 1000;
	}

	function updateCakePerBlock(uint256 _cakePerBlock) external onlyOwner
	{
		cakePerBlock = _cakePerBlock;
	}

	function updateMultiplier(uint256 _multiplierNumber) external onlyOwner
	{
		BONUS_MULTIPLIER = _multiplierNumber;
	}

	function poolLength() external view returns (uint256)
	{
		return poolInfo.length;
	}

	// Add a new lp to the pool. Can only be called by the owner.
	// XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
	function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) external onlyOwner
	{
		if (_withUpdate) {
			massUpdatePools();
		}
		uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
		totalAllocPoint = totalAllocPoint.add(_allocPoint);
		poolInfo.push(PoolInfo({
			lpToken: _lpToken,
			allocPoint: _allocPoint,
			lastRewardBlock: lastRewardBlock,
			accCakePerShare: 0
		}));
	}

	// Update the given pool's CAKE allocation point. Can only be called by the owner.
	function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner
	{
		if (_withUpdate) {
			massUpdatePools();
		}
		uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
		poolInfo[_pid].allocPoint = _allocPoint;
		if (prevAllocPoint != _allocPoint) {
			totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
		}
	}

	// Return reward multiplier over the given _from to _to block.
	function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256)
	{
		return _to.sub(_from).mul(BONUS_MULTIPLIER);
	}

	// View function to see pending CAKEs on frontend.
	function pendingCake(uint256 _pid, address _user) external view returns (uint256)
	{
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][_user];
		uint256 accCakePerShare = pool.accCakePerShare;
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (block.number > pool.lastRewardBlock && lpSupply != 0) {
			uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
			uint256 cakeReward = multiplier.mul(cakePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
			accCakePerShare = accCakePerShare.add(cakeReward.mul(1e12).div(lpSupply));
		}
		return user.amount.mul(accCakePerShare).div(1e12).sub(user.rewardDebt);
	}

	// Update reward variables for all pools. Be careful of gas spending!
	function massUpdatePools() public onlyEOAorWhitelist
	{
		uint256 length = poolInfo.length;
		for (uint256 pid = 0; pid < length; ++pid) {
			updatePool(pid);
		}
	}

	// Update reward variables of the given pool to be up-to-date.
	function updatePool(uint256 _pid) public onlyEOAorWhitelist
	{
		PoolInfo storage pool = poolInfo[_pid];
		if (block.number <= pool.lastRewardBlock) {
			return;
		}
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (lpSupply == 0) {
			pool.lastRewardBlock = block.number;
			return;
		}
		uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
		uint256 cakeReward = multiplier.mul(cakePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
		cake.mint(address(syrup), cakeReward);
		pool.accCakePerShare = pool.accCakePerShare.add(cakeReward.mul(1e12).div(lpSupply));
		pool.lastRewardBlock = block.number;
	}

	// Deposit LP tokens to MasterChef for CAKE allocation.
	function deposit(uint256 _pid, uint256 _amount) external onlyEOAorWhitelist
	{
		require(_pid != 0, "deposit CAKE by staking");
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		updatePool(_pid);
		if (user.amount > 0) {
			uint256 pending = user.amount.mul(pool.accCakePerShare).div(1e12).sub(user.rewardDebt);
			if (pending > 0) {
				safeCakeTransfer(msg.sender, pending);
			}
		}
		if (_amount > 0) {
			pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
			user.amount = user.amount.add(_amount);
		}
		user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
		emit Deposit(msg.sender, _pid, _amount);
	}

	// Withdraw LP tokens from MasterChef.
	function withdraw(uint256 _pid, uint256 _amount) external onlyEOAorWhitelist
	{
		require(_pid != 0, "withdraw CAKE by unstaking");
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		require(user.amount >= _amount, "withdraw: not good");
		updatePool(_pid);
		uint256 pending = user.amount.mul(pool.accCakePerShare).div(1e12).sub(user.rewardDebt);
		if (pending > 0) {
			safeCakeTransfer(msg.sender, pending);
		}
		if (_amount > 0) {
			user.amount = user.amount.sub(_amount);
			pool.lpToken.safeTransfer(address(msg.sender), _amount);
		}
		user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
		emit Withdraw(msg.sender, _pid, _amount);
	}

	// Stake CAKE tokens to MasterChef
	function enterStaking(uint256 _amount) external onlyEOAorWhitelist
	{
		PoolInfo storage pool = poolInfo[0];
		UserInfo storage user = userInfo[0][msg.sender];
		updatePool(0);
		if (user.amount > 0) {
			uint256 pending = user.amount.mul(pool.accCakePerShare).div(1e12).sub(user.rewardDebt);
			if (pending > 0) {
				safeCakeTransfer(msg.sender, pending);
			}
		}
		if (_amount > 0) {
			pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
			user.amount = user.amount.add(_amount);
		}
		user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
		syrup.mint(msg.sender, _amount);
		emit Deposit(msg.sender, 0, _amount);
	}

	// Withdraw CAKE tokens from STAKING.
	function leaveStaking(uint256 _amount) external onlyEOAorWhitelist
	{
		PoolInfo storage pool = poolInfo[0];
		UserInfo storage user = userInfo[0][msg.sender];
		require(user.amount >= _amount, "withdraw: not good");
		updatePool(0);
		uint256 pending = user.amount.mul(pool.accCakePerShare).div(1e12).sub(user.rewardDebt);
		if (pending > 0) {
			safeCakeTransfer(msg.sender, pending);
		}
		if (_amount > 0) {
			user.amount = user.amount.sub(_amount);
			pool.lpToken.safeTransfer(address(msg.sender), _amount);
		}
		user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
		syrup.burn(msg.sender, _amount);
		emit Withdraw(msg.sender, 0, _amount);
	}

	// Withdraw without caring about rewards. EMERGENCY ONLY.
	function emergencyWithdraw(uint256 _pid) external onlyEOAorWhitelist
	{
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		if (_pid == 0) syrup.burn(msg.sender, user.amount); // post deploy fix
		pool.lpToken.safeTransfer(address(msg.sender), user.amount);
		emit EmergencyWithdraw(msg.sender, _pid, user.amount);
		user.amount = 0;
		user.rewardDebt = 0;
	}

	// Safe cake transfer function, just in case if rounding error causes pool to not have enough CAKEs.
	function safeCakeTransfer(address _to, uint256 _amount) internal
	{
		syrup.safeCakeTransfer(_to, _amount);
	}
}
