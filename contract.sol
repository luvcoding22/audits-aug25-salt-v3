// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MyToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}


interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool);

    function mint(MintParams calldata params)
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function collect(CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
}

contract SaltCheckerAndDeployer {
    address public constant WETH = 0x3439153EB7AF838Ad19d56E1571FBD09333C2809;
    address public constant positionManager = 0xfA928D3ABc512383b8E5E77edd2d5678696084F9;
    uint24 public constant fee = 10000;
    address public constant ROUTER = 0x7712FA47387542819d4E35A23f8116C90C18767C;
    address public constant FEE_RECIPIENT = 0x20c0fc6B3cB4B25E610383C9945C2BC24a89A51e; // << nastav svoji adresu

    event TokenDeployed(address token, bytes32 salt);
    event PoolCreated(address pool);
    event LiquidityMinted(uint256 tokenId, uint128 liquidity);

    mapping(address => address) public poolForToken;
    mapping(address => uint256) public lpTokenIdForToken;
    mapping(address => address) public creatorForToken;

    function isSaltValid(bytes32 salt, string memory name, string memory symbol, uint256 supply) external view returns (bool valid, address predicted) {
        bytes memory bytecode = abi.encodePacked(
            type(MyToken).creationCode,
            abi.encode(name, symbol, supply, address(this))
        );

        predicted = computeAddress(address(this), salt, keccak256(bytecode));
        valid = predicted < WETH;
    }

    function deployMyTokenAndInitPool(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint256 supply,
        uint160 sqrtPriceX96
    ) external payable returns (address deployedToken, address pool) {
        bytes memory bytecode = abi.encodePacked(
            type(MyToken).creationCode,
            abi.encode(name, symbol, supply, address(this))
        );

        address predicted = computeAddress(address(this), salt, keccak256(bytecode));
        require(predicted < WETH, "Invalid salt: CA not less than WETH");

        deployedToken = deploy(bytecode, salt);
        emit TokenDeployed(deployedToken, salt);

        pool = INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
            deployedToken,
            WETH,
            fee,
            sqrtPriceX96
        );

        poolForToken[deployedToken] = pool;
        creatorForToken[deployedToken] = msg.sender;

        IERC20(deployedToken).approve(positionManager, type(uint256).max);

        uint256 fullBalance = IERC20(deployedToken).balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: deployedToken,
            token1: WETH,
            fee: fee,
            tickLower: -208200,
            tickUpper: 887200,
            amount0Desired: fullBalance, 
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1200
        });

        (uint256 tokenId, uint128 liquidity,,) = INonfungiblePositionManager(positionManager).mint(params);

        lpTokenIdForToken[deployedToken] = tokenId;
        emit LiquidityMinted(tokenId, liquidity);

        require(msg.value > 0, "Send ETH to swap");

        IWETH(WETH).deposit{value: msg.value}();
        IWETH(WETH).approve(ROUTER, msg.value);

        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: deployedToken,
            fee: fee,
            recipient: msg.sender,
            amountIn: msg.value,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        ISwapRouter(ROUTER).exactInputSingle(swapParams);
    }

    
    function collectFeesAndDistribute(address token, uint24 poolFee) external returns (uint256 totalETH) {
        uint256 tokenId = lpTokenIdForToken[token];
        require(tokenId > 0, "No LP tokenId");

        // 1️⃣ Claim fees
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 amount0, ) = INonfungiblePositionManager(positionManager).collect(collectParams);

        // 2️⃣ Swap na WETH
        if (amount0 > 0) {
            IERC20(token).approve(ROUTER, amount0);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: WETH,
                fee: poolFee,
                recipient: address(this),
                amountIn: amount0,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            ISwapRouter(ROUTER).exactInputSingle(params);
        }

        // 3️⃣ Celkový WETH
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        require(wethBalance > 0, "No WETH to distribute");

        // 4️⃣ Convert na ETH
        IWETH(WETH).withdraw(wethBalance);

        // 5️⃣ Split
        uint256 half = wethBalance / 2;
        address creator = creatorForToken[token];

        payable(FEE_RECIPIENT).transfer(half);
        payable(creator).transfer(wethBalance - half);

        return wethBalance;
    }



    function batchCollectFeesAndDistribute(address[] calldata tokens, uint24 poolFee) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 tokenId = lpTokenIdForToken[token];
            if (tokenId == 0) continue;

            // 1️⃣ Claim fees (token + WETH)
            INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

            (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager).collect(collectParams);

            uint256 wethFromSwap = 0;

            // 2️⃣ Pokud přišly tokeny (amount0), okamžitě je swapni na WETH
            if (amount0 > 0) {
                IERC20(token).approve(ROUTER, amount0);

                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: WETH,
                    fee: poolFee,
                    recipient: address(this),
                    amountIn: amount0,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });

                wethFromSwap = ISwapRouter(ROUTER).exactInputSingle(params);
            }

            // 3️⃣ Přičti claimnutý WETH
            wethFromSwap += amount1;

            if (wethFromSwap == 0) continue;

            // 4️⃣ Převod WETH -> ETH
            IWETH(WETH).withdraw(wethFromSwap);

            // 5️⃣ Rozdělení ETH
            uint256 half = wethFromSwap / 2;
            address creator = creatorForToken[token];

            payable(FEE_RECIPIENT).transfer(half);
            payable(creator).transfer(wethFromSwap - half);
        }
    }



    function computeAddress(address deployer, bytes32 salt, bytes32 _bytecodeHash) public pure returns (address) {
        return address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            _bytecodeHash
        )))));
    }

    function deploy(bytes memory bytecode, bytes32 salt) internal returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 32), mload(bytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
    }

    receive() external payable {}
}
