// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../contracts/interfaces/IPancakeFactory.sol";
import "../contracts/interfaces/IPancakeRouter01.sol";
import "../contracts/interfaces/IPancakeRouter02.sol";
import "../contracts/interfaces/IPancakePair.sol";

contract MVCC is Context, IERC20, Ownable {
    string private constant _name = "MVCC TOKEN";
    string private constant _symbol = "MVCC";
    uint8 private constant _decimals = 18;

    uint256 private constant MAX = ~uint256(0);
    uint256 private constant _tTotal = 10000000 * 10**18;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _tFeeTotal;

    address[] private _excluded;
    address public referralFeeReceiver;
    address public superNodeFeeReceiver;

    uint256 public referralFee = 5; 
    uint256 public superNodeFee = 2; 
    uint256 public liquidityFee = 2;  
    uint256 public taxFee = 1; // reflection
    uint256 public swapThreshold = _tTotal * 1/1000; //0.1%;
    
    // auto liquidity
    bool public _swapAndLiquifyEnabled = true;
    bool _inSwapAndLiquify;

    IPancakeRouter02 public _pancakeRouter;
    address public _pancakePair;

    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => bool) private _isExcludedFromFee;
    mapping (address => bool) private _isExcluded;
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping (address => bool) public _isExcludedFromAutoLiquidity;

    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }
    
    constructor (address _referralFeeReceiver, address _superNodeFeeReceiver) {
        _rOwned[_msgSender()] = _rTotal;
        
        // uniswap
        //Testnet 0xD99D1c33F9fC3444f8101754aBC46c52416550D1
        //Mainnet 0x10ED43C718714eb63d5aA57B78B54704E256024E
        IPancakeRouter02 pancakeRouter = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        _pancakeRouter = pancakeRouter;
        _pancakePair = IPancakeFactory(pancakeRouter.factory())
            .createPair(address(this), pancakeRouter.WETH());
        
        // exclude system contracts
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[_referralFeeReceiver] = true;
        _isExcludedFromFee[_superNodeFeeReceiver] = true;

        _isExcludedFromAutoLiquidity[_pancakePair] = true;
        _isExcludedFromAutoLiquidity[address(_pancakeRouter)] = true;

        referralFeeReceiver = _referralFeeReceiver;
        superNodeFeeReceiver = _superNodeFeeReceiver;
        
        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    function name() external pure returns (string memory) {
        return _name;
    }

    function symbol() external pure returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() external pure override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()] - amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] - subtractedValue);
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "BEP20: approve from the zero address");
        require(spender != address(0), "BEP20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        require(from != address(0), "BEP20: transfer from the zero address");
        require(to != address(0), "BEP20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        uint256 contractTokenBalance = balanceOf(address(this));
        
        bool isOverMinTokenBalance = contractTokenBalance >= swapThreshold;
        if (
            isOverMinTokenBalance &&
            !_inSwapAndLiquify &&
            !_isExcludedFromAutoLiquidity[from] &&
            _swapAndLiquifyEnabled
        ) {
            swapAndLiquify(contractTokenBalance);
        }

        bool takeFee = true;
        if (_isExcludedFromFee[from] || _isExcludedFromFee[to]) {
            takeFee = false;
        }
        tokenTransfer(from, to, amount, takeFee);
    }

    function swapAndLiquify(uint256 contractTokenBalance) internal lockTheSwap {
        // split the contract balance into halves
        uint256 half = contractTokenBalance / 2;
        uint256 otherHalf = contractTokenBalance - half;

        // capture the contract's current BNB balance.
        // this is so that we can capture exactly the amount of BNB that the
        // swap creates, and not make the liquidity event include any BNB that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for BNB
        swapTokensForBnb(half); // <- this breaks the BNB -> HATE swap when swap+liquify is triggered

        // how much BNB did we just swap into?
        uint256 newBalance = address(this).balance - initialBalance;

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);
        
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForBnb(uint256 tokenAmount) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _pancakeRouter.WETH();

        _approve(address(this), address(_pancakeRouter), tokenAmount);

        // make the swap
        _pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of BNB
            path,
            address(this),
            block.timestamp
        );

        emit SwapTokensForBnb(tokenAmount);
    }

    function addLiquidity(uint256 tokenAmount, uint256 bnbAmount) internal {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_pancakeRouter), tokenAmount);

        // add the liquidity
        _pancakeRouter.addLiquidityETH{value: bnbAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );

        emit AddLiquidity(tokenAmount, bnbAmount);
    }

    function deliver(uint256 tAmount) external {
        address sender = _msgSender();
        require(!_isExcluded[sender], "Excluded addresses cannot call this function");

        (, uint256 tFee, uint256 tLiquidity, uint256 tReferral, uint256 tSuperNode) = getTValues(tAmount);
        uint256 currentRate = getRate();
        (uint256 rAmount,,, uint256 rReferralFee, uint256 rSuperNodeFee) = getRValues(tAmount, tFee, tLiquidity, tReferral, tSuperNode, currentRate);

        _rOwned[sender] = _rOwned[sender] - rAmount;
        _rOwned[referralFeeReceiver] = _rOwned[referralFeeReceiver] + rReferralFee;
        _rOwned[superNodeFeeReceiver] = _rOwned[superNodeFeeReceiver] + rSuperNodeFee;
        _rTotal = _rTotal - rAmount;
        _tFeeTotal = _tFeeTotal + tAmount;

        emit Deliver(tAmount);
    }

    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");

        uint256 currentRate = getRate();
        return rAmount / currentRate;
    }

    function tokenTransfer(address sender, address recipient, uint256 amount,bool takeFee) internal {
        uint256 previousTaxFee = taxFee;
        uint256 previousLiquidityFee = liquidityFee;
        uint256 previousReferralFee = referralFee;
        uint256 previousSuperNodeFee = superNodeFee;
        
        if (!takeFee) {
            taxFee = 0;
            liquidityFee = 0;
            referralFee = 0;
            superNodeFee = 0;
        }
        
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            transferToExcluded(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            transferBothExcluded(sender, recipient, amount);
        } else {
            transferStandard(sender, recipient, amount);
        }
        
        if (!takeFee) {
            taxFee = previousTaxFee;
            liquidityFee = previousLiquidityFee;
            referralFee = previousReferralFee;
            superNodeFee = previousSuperNodeFee;
        }
    }

    function transferStandard(address sender, address recipient, uint256 tAmount) internal {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tReferral, uint256 tSuperNode) = getTValues(tAmount);
        uint256 currentRate = getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee,,) = getRValues(tAmount, tFee, tReferral, tSuperNode, tLiquidity, currentRate);

        _rOwned[sender] = _rOwned[sender] - rAmount;
        _rOwned[recipient] = _rOwned[recipient] + rTransferAmount;

        takeTransactionFee(address(this), tLiquidity, currentRate);
        takeTransactionFee(referralFeeReceiver, tReferral, currentRate);
        takeTransactionFee(superNodeFeeReceiver, tSuperNode, currentRate);
        reflectFee(rFee, tFee);

        emit Transfer(sender, recipient, tTransferAmount);
    }

    function transferBothExcluded(address sender, address recipient, uint256 tAmount) internal {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tReferral, uint256 tSuperNode) = getTValues(tAmount);
        uint256 currentRate = getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee,,) = getRValues(tAmount, tFee, tReferral, tSuperNode, tLiquidity, currentRate);

        _tOwned[sender] = _tOwned[sender] - tAmount;
        _rOwned[sender] = _rOwned[sender] - rAmount;
        _tOwned[recipient] = _tOwned[recipient] + tTransferAmount;
        _rOwned[recipient] = _rOwned[recipient] + rTransferAmount;

        takeTransactionFee(address(this), tLiquidity, currentRate);
        reflectFee(rFee, tFee);

        emit Transfer(sender, recipient, tTransferAmount);
    }

    function transferToExcluded(address sender, address recipient, uint256 tAmount) internal {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tReferral, uint256 tSuperNode) = getTValues(tAmount);
        uint256 currentRate = getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee,,) = getRValues(tAmount, tFee, tReferral, tSuperNode, tLiquidity, currentRate);

        _rOwned[sender] = _rOwned[sender] - rAmount;
        _tOwned[recipient] = _tOwned[recipient] + tTransferAmount;
        _rOwned[recipient] = _rOwned[recipient] + rTransferAmount;

        takeTransactionFee(address(this), tLiquidity, currentRate);
        reflectFee(rFee, tFee);

        emit Transfer(sender, recipient, tTransferAmount);
    }

    function transferFromExcluded(address sender, address recipient, uint256 tAmount) internal {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tReferral, uint256 tSuperNode) = getTValues(tAmount);
        uint256 currentRate = getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee,,) = getRValues(tAmount, tFee, tReferral, tSuperNode, tLiquidity, currentRate);

        _tOwned[sender] = _tOwned[sender] - tAmount;
        _rOwned[sender] = _rOwned[sender] - rAmount;
        _rOwned[recipient] = _rOwned[recipient] + rTransferAmount;
        
        takeTransactionFee(address(this), tLiquidity, currentRate);
        reflectFee(rFee, tFee);

        emit Transfer(sender, recipient, tTransferAmount);
    }

    function reflectFee(uint256 rFee, uint256 tFee) internal {
        _rTotal    = _rTotal - rFee;
        _tFeeTotal = _tFeeTotal + tFee;
    }

    function takeTransactionFee(address to, uint256 tAmount, uint256 currentRate) internal {
        if (tAmount <= 0) { return; }

        uint256 rAmount = tAmount * currentRate;
        _rOwned[to] = _rOwned[to] + rAmount;
        if (_isExcluded[to]) {
            _tOwned[to] = _tOwned[to] + tAmount;
        }

        emit Transfer(address(this), to, tAmount);
    }
    
    function calculateFee(uint256 amount, uint256 fee) internal pure returns (uint256) {
        return amount * fee / 100;
    }

    function totalFees() external view returns (uint256) {
        return _tFeeTotal;
    }
    
    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }

    function isExcludedFromReward(address account) external view returns (bool) {
        return _isExcluded[account];
    }

    function rescueToken(address tokenAddress, address to) external onlyOwner {
        uint256 contractBalance = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).transfer(to, contractBalance);
    }

    receive() external payable {}

    // ===================================================================
    // GETTERS
    // ===================================================================

    function getTValues(uint256 tAmount) internal view returns (uint256, uint256, uint256, uint256, uint256) {
        uint256 tFee = calculateFee(tAmount, taxFee);
        uint256 tLiquidity = calculateFee(tAmount, liquidityFee);
        uint256 tReferral = calculateFee(tAmount, referralFee);
        uint256 tSuperNode = calculateFee(tAmount, superNodeFee);
        uint256 tTransferAmount = tAmount - (tFee + tLiquidity + tReferral + tSuperNode);
        return (tTransferAmount, tFee, tLiquidity, tReferral, tSuperNode);
    }

    function getRValues(uint256 tAmount, uint256 tFee, uint256 tLiquidity, uint256 tReferral, uint256 tSuperNode, uint256 currentRate) 
    internal pure returns (uint256, uint256, uint256, uint256, uint256) {
        uint256 rAmount = tAmount * currentRate;
        uint256 rFee = tFee * currentRate;
        uint256 rLiquidity = tLiquidity * currentRate;
        uint256 rReferral = tReferral * currentRate;
        uint256 rSuperNode = tSuperNode * currentRate;
        uint256 rTransferAmount = rAmount - (rFee + rLiquidity + rReferral + rSuperNode);
        return (rAmount, rTransferAmount, rFee, rReferral, rSuperNode);
    }

    function getRate() internal view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = getCurrentSupply();
        return rSupply / tSupply;
    }

    function getCurrentSupply() internal view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply - _rOwned[_excluded[i]];
            tSupply = tSupply - _tOwned[_excluded[i]];
        }
        if (rSupply < _rTotal / _tTotal) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    // ===================================================================
    // SETTERS
    // ===================================================================

    function setExcludeFromReward(address account) external onlyOwner {
        require(account != address(0), "Address zero");
        require(!_isExcluded[account], "Account is already excluded");

        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);

        emit SetExcludeFromReward(account);
    }

    function setIncludeInReward(address account) external onlyOwner {
        require(account != address(0), "Address zero");
        require(_isExcluded[account], "Account is not excluded");

        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }

        emit SetIncludeInReward(account);
    }

    function setReferralFeeReceiver(address newReferralFeeReceiver) external onlyOwner {
        require(newReferralFeeReceiver != address(0), "Address zero");
        referralFeeReceiver = newReferralFeeReceiver;

        emit SetReferralFeeReceiver(newReferralFeeReceiver);
    }

    function setSuperNodeFeeReceiver(address newSuperNodeFeeReceiver) external onlyOwner {
        require(newSuperNodeFeeReceiver != address(0), "Address zero");
        superNodeFeeReceiver = newSuperNodeFeeReceiver;

        emit SetSuperNodeFeeReceiver(newSuperNodeFeeReceiver);
    }

    function setExcludedFromFee(address addr, bool e) external onlyOwner {
        require(addr != address(0), "Address zero");
        _isExcludedFromFee[addr] = e;

        emit SetExcludedFromFee(addr, e);
    }
    
    function setTaxFeePercent(uint256 newTaxFee) external onlyOwner {
        require(newTaxFee <= 5, "Exceeded 5 percent");
        taxFee = newTaxFee;

        emit SetTaxFeePercent(newTaxFee);
    }

    function setLiquidityFeePercent(uint256 newLiquidityFee) external onlyOwner {
        require(newLiquidityFee <= 5, "Exceeded 5 percent");
        liquidityFee = newLiquidityFee;

        emit SetLiquidityFeePercent(newLiquidityFee);
    }

    function setReferralFeePercent(uint256 newReferralFee) external onlyOwner {
        require(newReferralFee <= 5, "Exceeded 5 percent");
        referralFee = newReferralFee;

        emit SetReferralFeePercent(newReferralFee);
    }

    function setSuperNodeFeePercent(uint256 newSuperNodeFee) external onlyOwner {
        require(newSuperNodeFee <= 5, "Exceeded 5 percent");
        superNodeFee = newSuperNodeFee;

        emit SetSuperNodeFeePercent(newSuperNodeFee);
    }

    function setSwapAndLiquifyEnabled(bool e) external onlyOwner {
        _swapAndLiquifyEnabled = e;

        emit SwapAndLiquifyEnabledUpdated(e);
    }

    function setSwapThreshold(uint256 newSwapThreshold) external onlyOwner {
        require(newSwapThreshold > 0, "must be larger than zero");
        swapThreshold = newSwapThreshold;

        emit SetSwapThreshold(newSwapThreshold);
    }
    
    function setUniswapRouter(address newUniswapRouter) external onlyOwner {
        require(newUniswapRouter != address(0), "Address zero");
        IPancakeRouter02 pancakeRouter = IPancakeRouter02(newUniswapRouter);
        _pancakeRouter = pancakeRouter;

        emit SetUniswapRouter(newUniswapRouter);
    }

    function setUniswapPair(address newUniswapPair) external onlyOwner {
        require(newUniswapPair != address(0), "Address zero");
        _pancakePair = newUniswapPair;

        emit SetUniswapPair(newUniswapPair);
    }

    function setExcludedFromAutoLiquidity(address addr, bool b) external onlyOwner {
        require(addr != address(0), "Address zero");
        _isExcludedFromAutoLiquidity[addr] = b;

        emit SetExcludedFromAutoLiquidity(addr, b);
    }

    // ===================================================================
    // EVENTS
    // ===================================================================

    event Deliver(uint256 tAmount);
    event SetExcludeFromReward(address account);
    event SetIncludeInReward(address account);
    event SetReferralFeeReceiver(address referralWallet);
    event SetSuperNodeFeeReceiver(address superNodeWallet);
    event SetExcludedFromFee(address account, bool e);
    event SetTaxFeePercent(uint256 taxFee);
    event SetLiquidityFeePercent(uint256 liquidityFee);
    event SetReferralFeePercent(uint256 referralFee);
    event SetSuperNodeFeePercent(uint256 superNodeFee);
    event SetSwapAndLiquifyEnabled(bool e);
    event SetSwapThreshold(uint256 swapThreshold);
    event SetUniswapRouter(address uniswapRouter);
    event SetUniswapPair(address uniswapPair);
    event SetExcludedFromAutoLiquidity(address a, bool b);
    event RescueToken(address tokenAddress, address to);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapTokensForBnb(uint256 tokenAmount);
    event AddLiquidity(uint256 tokenAmount, uint256 bnbAmount);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiquidity);
}