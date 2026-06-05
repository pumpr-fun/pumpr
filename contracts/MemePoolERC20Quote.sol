// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Quote {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2RouterERC20Like {
    function factory() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IUniswapV2FactoryERC20Like {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @title MemePoolERC20Quote
/// @notice Bonding-curve pool quoted in an ERC-20 asset such as USDC.
contract MemePoolERC20Quote {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant QUOTE_DECIMAL_SCALE = 1e12;

    address public immutable factory;
    address public immutable token;
    address public immutable quoteToken;
    address public feeRecipient;

    uint256 public feeBps;
    uint256 public quoteReserve;
    uint256 public tokenReserve;
    uint256 public virtualQuoteReserve;
    uint256 public virtualTokenReserve;

    uint256 public graduationTargetQuote;
    address public dexRouter;
    address public lpRecipient;

    bool public initialized;
    bool public seeded;
    bool public graduated;
    bool private locked;

    address public migratedPair;
    uint256 public graduatedAt;

    event PoolSeeded(uint256 tokenLiquidity);
    event Buy(address indexed buyer, uint256 ethIn, uint256 feePaid, uint256 tokensOut);
    event Sell(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 feePaid);
    event QuoteBuy(address indexed buyer, address indexed quoteToken, uint256 quoteIn, uint256 feePaid, uint256 tokensOut);
    event QuoteSell(address indexed seller, address indexed quoteToken, uint256 tokensIn, uint256 quoteOut, uint256 feePaid);
    event FeeConfigUpdated(address indexed recipient, uint256 feeBps);
    event MigrationConfigUpdated(address dexRouter, address lpRecipient, uint256 graduationTargetQuote);
    event Graduated(
        address indexed pair,
        uint256 tokenMigrated,
        uint256 quoteMigrated,
        uint256 lpMinted,
        uint256 timestamp
    );

    modifier onlyFactory() {
        require(msg.sender == factory, "only factory");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    constructor(
        address _token,
        address _quoteToken
    ) {
        require(_token != address(0), "token required");
        require(_quoteToken != address(0), "quote required");

        token = _token;
        quoteToken = _quoteToken;
        factory = msg.sender;
    }

    function initialize(
        address _feeRecipient,
        uint256 _feeBps,
        uint256 _virtualQuoteReserve,
        uint256 _virtualTokenReserve,
        uint256 _graduationTargetQuote,
        address _dexRouter,
        address _lpRecipient
    ) external onlyFactory {
        require(!initialized, "already initialized");
        require(_feeRecipient != address(0), "fee recipient required");
        require(_feeBps <= 300, "fee too high");
        require(_virtualQuoteReserve > 0, "virtual quote required");
        require(_virtualTokenReserve > 0, "virtual token required");
        require(_graduationTargetQuote > 0, "target required");

        if (_dexRouter != address(0)) {
            require(_lpRecipient != address(0), "lp recipient required");
        }

        initialized = true;
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
        virtualQuoteReserve = _virtualQuoteReserve;
        virtualTokenReserve = _virtualTokenReserve;
        graduationTargetQuote = _graduationTargetQuote;
        dexRouter = _dexRouter;
        lpRecipient = _lpRecipient;
    }

    function seed(uint256 tokenAmount) external onlyFactory {
        require(!seeded, "already seeded");
        require(initialized, "not initialized");
        require(tokenAmount > 0, "token amount required");
        require(IERC20Quote(token).balanceOf(address(this)) >= tokenAmount, "insufficient tokens");

        seeded = true;
        tokenReserve = tokenAmount;

        emit PoolSeeded(tokenAmount);
    }

    function configureFees(address newRecipient, uint256 newFeeBps) external onlyFactory {
        require(newRecipient != address(0), "recipient required");
        require(newFeeBps <= 300, "fee too high");

        feeRecipient = newRecipient;
        feeBps = newFeeBps;

        emit FeeConfigUpdated(newRecipient, newFeeBps);
    }

    function configureMigration(address newDexRouter, address newLpRecipient, uint256 newTargetQuote) external onlyFactory {
        require(!graduated, "already graduated");
        require(newTargetQuote > 0, "target required");

        if (newDexRouter != address(0)) {
            require(newLpRecipient != address(0), "lp recipient required");
        }

        dexRouter = newDexRouter;
        lpRecipient = newLpRecipient;
        graduationTargetQuote = newTargetQuote;

        emit MigrationConfigUpdated(newDexRouter, newLpRecipient, newTargetQuote);
    }

    function buyWithQuote(uint256 quoteAmountIn, uint256 minTokensOut) external nonReentrant returns (uint256 tokensOut) {
        require(seeded, "pool not seeded");
        require(!graduated, "graduated");
        require(quoteAmountIn > 0, "quote required");

        uint256 feePaid = (quoteAmountIn * feeBps) / BPS_DENOMINATOR;
        uint256 netQuoteIn = quoteAmountIn - feePaid;
        tokensOut = _getBuyQuoteFromNetQuote(netQuoteIn);

        require(tokensOut > 0, "insufficient output");
        require(tokensOut >= minTokensOut, "slippage");
        require(tokensOut <= tokenReserve, "insufficient liquidity");

        require(IERC20Quote(quoteToken).transferFrom(msg.sender, address(this), quoteAmountIn), "quote transfer failed");
        if (feePaid > 0) {
            require(IERC20Quote(quoteToken).transfer(feeRecipient, feePaid), "fee transfer failed");
        }

        quoteReserve += netQuoteIn;
        tokenReserve -= tokensOut;

        require(IERC20Quote(token).transfer(msg.sender, tokensOut), "token transfer failed");

        emit Buy(msg.sender, quoteAmountIn, feePaid, tokensOut);
        emit QuoteBuy(msg.sender, quoteToken, quoteAmountIn, feePaid, tokensOut);

        _tryAutoGraduate();
    }

    function sell(uint256 tokenAmountIn, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        require(seeded, "pool not seeded");
        require(!graduated, "graduated");
        require(tokenAmountIn > 0, "token amount required");

        uint256 grossQuoteOut = _getSellQuoteGross(tokenAmountIn);
        require(grossQuoteOut > 0, "insufficient output");
        require(grossQuoteOut <= quoteReserve, "insufficient quote reserve");

        uint256 feePaid = (grossQuoteOut * feeBps) / BPS_DENOMINATOR;
        quoteOut = grossQuoteOut - feePaid;

        require(quoteOut >= minQuoteOut, "slippage");
        require(IERC20Quote(token).transferFrom(msg.sender, address(this), tokenAmountIn), "token transfer failed");

        tokenReserve += tokenAmountIn;
        quoteReserve -= grossQuoteOut;

        require(IERC20Quote(quoteToken).transfer(msg.sender, quoteOut), "quote transfer failed");
        if (feePaid > 0) {
            require(IERC20Quote(quoteToken).transfer(feeRecipient, feePaid), "fee transfer failed");
        }

        emit Sell(msg.sender, tokenAmountIn, quoteOut, feePaid);
        emit QuoteSell(msg.sender, quoteToken, tokenAmountIn, quoteOut, feePaid);
    }

    function triggerGraduation() external nonReentrant {
        require(seeded, "pool not seeded");
        require(!graduated, "already graduated");
        require(quoteReserve >= graduationTargetQuote, "target not reached");

        _graduateToDex();
    }

    function quoteBuy(uint256 quoteAmountIn) external view returns (uint256 tokensOut, uint256 feePaid) {
        if (!seeded || graduated || quoteAmountIn == 0) {
            return (0, 0);
        }

        feePaid = (quoteAmountIn * feeBps) / BPS_DENOMINATOR;
        uint256 netQuote = quoteAmountIn - feePaid;
        tokensOut = _getBuyQuoteFromNetQuote(netQuote);
    }

    function quoteSell(uint256 tokenAmountIn) external view returns (uint256 quoteOut, uint256 feePaid) {
        if (!seeded || graduated || tokenAmountIn == 0) {
            return (0, 0);
        }

        uint256 grossQuoteOut = _getSellQuoteGross(tokenAmountIn);
        if (grossQuoteOut == 0) {
            return (0, 0);
        }

        feePaid = (grossQuoteOut * feeBps) / BPS_DENOMINATOR;
        quoteOut = grossQuoteOut - feePaid;
    }

    function spotPrice() external view returns (uint256) {
        uint256 y = tokenReserve + virtualTokenReserve;
        if (y == 0) {
            return 0;
        }

        uint256 x = quoteReserve + virtualQuoteReserve;
        return (x * QUOTE_DECIMAL_SCALE * 1e18) / y;
    }

    function targetProgressBps() external view returns (uint256) {
        if (graduationTargetQuote == 0) {
            return 0;
        }

        uint256 progress = (quoteReserve * BPS_DENOMINATOR) / graduationTargetQuote;
        if (progress > BPS_DENOMINATOR) {
            return BPS_DENOMINATOR;
        }

        return progress;
    }

    function ethReserve() external view returns (uint256) {
        return quoteReserve;
    }

    function virtualEthReserve() external view returns (uint256) {
        return virtualQuoteReserve;
    }

    function graduationTargetEth() external view returns (uint256) {
        return graduationTargetQuote;
    }

    function _tryAutoGraduate() internal {
        if (graduated || quoteReserve < graduationTargetQuote) {
            return;
        }

        _graduateToDex();
    }

    function _graduateToDex() internal {
        require(dexRouter != address(0), "dex router not set");

        graduated = true;
        graduatedAt = block.timestamp;

        uint256 tokensToMigrate = tokenReserve;
        uint256 quoteToMigrate = quoteReserve;

        tokenReserve = 0;
        quoteReserve = 0;

        IERC20Quote(token).approve(dexRouter, 0);
        IERC20Quote(token).approve(dexRouter, tokensToMigrate);
        IERC20Quote(quoteToken).approve(dexRouter, 0);
        IERC20Quote(quoteToken).approve(dexRouter, quoteToMigrate);

        (uint256 tokenUsed, uint256 quoteUsed, uint256 lpMinted) = _addDexLiquidity(tokensToMigrate, quoteToMigrate);

        migratedPair = _readPair();

        if (tokensToMigrate > tokenUsed) {
            require(IERC20Quote(token).transfer(feeRecipient, tokensToMigrate - tokenUsed), "token dust transfer failed");
        }

        if (quoteToMigrate > quoteUsed) {
            require(IERC20Quote(quoteToken).transfer(feeRecipient, quoteToMigrate - quoteUsed), "quote dust transfer failed");
        }

        emit Graduated(migratedPair, tokenUsed, quoteUsed, lpMinted, block.timestamp);
    }

    function _addDexLiquidity(uint256 tokensToMigrate, uint256 quoteToMigrate)
        internal
        returns (uint256 tokenUsed, uint256 quoteUsed, uint256 lpMinted)
    {
        return IUniswapV2RouterERC20Like(dexRouter).addLiquidity(
            token,
            quoteToken,
            tokensToMigrate,
            quoteToMigrate,
            0,
            0,
            lpRecipient,
            block.timestamp + 1 hours
        );
    }

    function _readPair() internal view returns (address) {
        address routerFactory = IUniswapV2RouterERC20Like(dexRouter).factory();
        return IUniswapV2FactoryERC20Like(routerFactory).getPair(token, quoteToken);
    }

    function _getBuyQuoteFromNetQuote(uint256 netQuoteIn) internal view returns (uint256) {
        if (netQuoteIn == 0) {
            return 0;
        }

        uint256 x = quoteReserve + virtualQuoteReserve;
        uint256 y = tokenReserve + virtualTokenReserve;
        uint256 k = x * y;

        uint256 newX = x + netQuoteIn;
        uint256 newY = k / newX;

        if (y <= newY) {
            return 0;
        }

        uint256 tokensOut = y - newY;
        if (tokensOut > tokenReserve) {
            return tokenReserve;
        }

        return tokensOut;
    }

    function _getSellQuoteGross(uint256 tokenAmountIn) internal view returns (uint256) {
        uint256 x = quoteReserve + virtualQuoteReserve;
        uint256 y = tokenReserve + virtualTokenReserve;
        uint256 k = x * y;

        uint256 newY = y + tokenAmountIn;
        uint256 newX = k / newY;

        if (x <= newX) {
            return 0;
        }

        uint256 grossQuoteOut = x - newX;
        if (grossQuoteOut > quoteReserve) {
            return quoteReserve;
        }

        return grossQuoteOut;
    }
}
