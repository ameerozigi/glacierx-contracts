// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOracle
/// @notice Minimal Chainlink AggregatorV3Interface used by GlacierX Protocol
/// @dev Matches the Chainlink AggregatorV3Interface exactly; no external dependency needed
interface IOracle {
    /// @notice Get the latest price round data from Chainlink
    /// @return roundId       The round identifier
    /// @return answer        The price (note: Chainlink ETH/USD is 8 decimals)
    /// @return startedAt     Timestamp the round started
    /// @return updatedAt     Timestamp the round was updated — used for staleness checks
    /// @return answeredInRound The round in which the answer was computed
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /// @notice Returns the number of decimals in the answer (8 for ETH/USD)
    function decimals() external view returns (uint8);
}
