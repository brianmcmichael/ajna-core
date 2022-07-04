// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import { console } from "@std/console.sol";

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import { IERC20Pool }       from "../erc20/interfaces/IERC20Pool.sol";
import { IERC721Pool }      from "../erc721/interfaces/IERC721Pool.sol";
import { ILenderManager }   from "./interfaces/ILenderManager.sol";
import { IPool }            from "./interfaces/IPool.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";

import { Multicall }   from "./Multicall.sol";
import { PermitERC20 } from "./PermitERC20.sol";
import { PositionNFT } from "./PositionNFT.sol";

import { Maths } from "../libraries/Maths.sol";

contract PositionManager is IPositionManager, Multicall, PositionNFT, PermitERC20 {

    constructor() PositionNFT("Ajna Positions NFT-V1", "AJNA-V1-POS", "1") {}

    /***********************/
    /*** State Variables ***/
    /***********************/

    /** @dev Mapping of tokenIds to Position struct */
    mapping(uint256 => Position) public positions;

    /** @dev Mapping of tokenIds to Pool address */
    mapping(uint256 => address) public poolKey;

    /** @dev The ID of the next token that will be minted. Skips 0 */
    uint176 private _nextId = 1;

    /*****************/
    /*** Modifiers ***/
    /*****************/

    modifier mayInteract(address pool_, uint256 tokenId_) {
        require(_isApprovedOrOwner(msg.sender, tokenId_), "PM:NO_AUTH");
        require(pool_ == poolKey[tokenId_], "PM:W_POOL");
        _;
    }

    /************************/
    /*** Lender Functions ***/
    /************************/

    // TODO: Update burn check to ensure all position prices have removed liquidity
    function burn(BurnParams calldata params_) external override payable mayInteract(params_.pool, params_.tokenId) {
        require(positions[params_.tokenId].lpTokens[params_.price] == 0, "PM:B:LIQ_NOT_REMOVED");
        emit Burn(msg.sender, params_.price);
        delete positions[params_.tokenId];
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params_) external override payable mayInteract(params_.pool, params_.tokenId) {
        IERC20Pool pool = IERC20Pool(params_.pool);

        // calculate equivalent underlying assets for given lpTokens
        (uint256 collateralToRemove, uint256 quoteTokenToRemove) = ILenderManager(params_.pool).getLPTokenExchangeValue(params_.lpTokens, params_.price);

        pool.removeQuoteToken(params_.recipient, quoteTokenToRemove, params_.price);

        // enable lenders to remove quote token from a bucket that no debt is added to
        if (collateralToRemove != 0) {
            // claim any unencumbered collateral accrued to the price bucket
            pool.claimCollateral(params_.recipient, collateralToRemove, params_.price);
        }

        // update position with newly removed lp shares
        positions[params_.tokenId].lpTokens[params_.price] -= params_.lpTokens;

        emit DecreaseLiquidity(params_.recipient, params_.price, collateralToRemove, quoteTokenToRemove);
    }

    function decreaseLiquidityNFT(DecreaseLiquidityNFTParams calldata params_) external override payable mayInteract(params_.pool, params_.tokenId) {
        IERC721Pool pool = IERC721Pool(params_.pool);

        // calculate equivalent underlying assets for given lpTokens
        (uint256 collateralToRemove, uint256 quoteTokenToRemove) = ILenderManager(params_.pool).getLPTokenExchangeValue(params_.lpTokens, params_.price);

        // enable lenders to remove quote token from a bucket that no debt is added to
        if (collateralToRemove != 0) {
            // slice incoming tokens to only use as many as are required
            uint256 indexToUse = Maths.wadToIntRoundingDown(collateralToRemove);
            uint256[] memory tokensToRemove = new uint256[](indexToUse);
            tokensToRemove = params_.tokenIdsToRemove[:indexToUse];

            // claim any unencumbered collateral accrued to the price bucket
            pool.claimCollateral(params_.recipient, tokensToRemove, params_.price);

            // update position with newly removed lp shares
            positions[params_.tokenId].lpTokens[params_.price] -= params_.lpTokens;

            emit DecreaseLiquidityNFT(params_.recipient, params_.price, tokensToRemove, quoteTokenToRemove);
        }
        else {
            // update position with newly removed lp shares
            positions[params_.tokenId].lpTokens[params_.price] -= params_.lpTokens;

            uint[] memory emptyArray = new uint[](0);
            emit DecreaseLiquidityNFT(params_.recipient, params_.price, emptyArray, quoteTokenToRemove);
        }
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params_) external override payable mayInteract(params_.pool, params_.tokenId) {
        // Call out to pool contract to add quote tokens
        uint256 lpTokensAdded = IPool(params_.pool).addQuoteToken(params_.recipient, params_.amount, params_.price);
        // TODO: figure out how to test this case
        require(lpTokensAdded != 0, "PM:IL:NO_LP_TOKENS");

        // update position with newly added lp shares
        positions[params_.tokenId].lpTokens[params_.price] += lpTokensAdded;

        emit IncreaseLiquidity(params_.recipient, params_.price, params_.amount);
    }

    /// TODO: (X) prices can be memorialized at a time
    function memorializePositions(MemorializePositionsParams calldata params_) external override {
        Position storage position = positions[params_.tokenId];
        for (uint256 i = 0; i < params_.prices.length; ) {
            position.lpTokens[params_.prices[i]] = ILenderManager(params_.pool).lpBalance(
                params_.owner,
                params_.prices[i]
            );
            // increment call counter in gas efficient way by skipping safemath checks
            unchecked {
                ++i;
            }
        }

        emit MemorializePosition(params_.owner, params_.tokenId);
    }

    function mint(MintParams calldata params_) external override payable returns (uint256 tokenId_) {
        _safeMint(params_.recipient, (tokenId_ = _nextId++));

        // create a new position associated with the newly minted tokenId
        positions[tokenId_].pool = params_.pool;

        // record which pool the tokenId was minted in
        poolKey[tokenId_] = params_.pool;

        emit Mint(params_.recipient, params_.pool, tokenId_);
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    /**
     * @notice Override ERC721 afterTokenTransfer hook to ensure that transferred NFT's are properly tracked within the PositionManager data struct
     * @dev    This call also executes upon Mint
    */
    function _afterTokenTransfer(address, address to_, uint256 tokenId_) internal virtual override(ERC721) {
        positions[tokenId_].owner = to_;
    }

    /** @dev Used for tracking nonce input to permit function */
    function _getAndIncrementNonce(uint256 tokenId_) internal override returns (uint256) {
        return uint256(positions[tokenId_].nonce++);
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function getLPTokens(uint256 tokenId_, uint256 price_) external override view returns (uint256) {
        return positions[tokenId_].lpTokens[price_];
    }

    function getPositionValueInQuoteTokens(uint256 tokenId_, uint256 price_) external override view returns (uint256) {
        Position storage position = positions[tokenId_];

        (uint256 collateral, uint256 quote) = ILenderManager(position.pool).getLPTokenExchangeValue(
            position.lpTokens[price_],
            price_
        );

        return quote + (collateral * price_);
    }

    function tokenURI(uint256 tokenId_) public view override(ERC721) returns (string memory) {
        require(_exists(tokenId_));

        // TODO: access the prices at which a tokenId has added liquidity
        uint256[] memory prices;

        ConstructTokenURIParams memory params = ConstructTokenURIParams(tokenId_, positions[tokenId_].pool, prices);

        return constructTokenURI(params);
    }

}