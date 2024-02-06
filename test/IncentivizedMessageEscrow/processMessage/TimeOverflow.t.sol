// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { TestCommon } from "../../TestCommon.t.sol";


contract TimeOverflowTest is TestCommon {

    uint256 _receive;

    event Message(
        bytes32 destinationIdentifier,
        bytes recipient,
        bytes message
    );

    function test_larger_than_uint_time_is_fine() public {
        vm.warp(2**64 + 1 days);
        bytes memory message = _MESSAGE;
        bytes32 feeRecipient = bytes32(uint256(uint160(address(this))));

        bytes32 destinationFeeRecipient = bytes32(uint256(uint160(BOB)));

        (bytes32 messageIdentifier, bytes memory messageWithContext) = setupForAck(address(application), message, destinationFeeRecipient);

        vm.warp(2**64 + 1 days + _INCENTIVE.targetDelta);

        (uint8 v, bytes32 r, bytes32 s) = signMessageForMock(messageWithContext);
        bytes memory mockContext = abi.encode(v, r, s);

        vm.expectEmit();
        emit MessageAcked(messageIdentifier);

        escrow.processPacket(
            mockContext,
            messageWithContext,
            feeRecipient
        );
    }

    // This function tests the following snippit of the code
    // unchecked {
    //     executionTime = uint64(block.timestamp) - uint64(bytes8(message[CTX1_EXECUTION_TIME_START:CTX1_EXECUTION_TIME_END]));
    // }
    function test_overflow_in_unchecked_is_fine() public {
        uint256 timeDiff = _INCENTIVE.targetDelta;
        uint256 initialTime = 2**64 - 1 - timeDiff/2;
        uint256 postTime = initialTime + timeDiff;
        require(uint64(initialTime) > uint64(postTime));  // This is what we want to ensure works properly.
        vm.warp(initialTime);
        bytes memory message = _MESSAGE;
        bytes32 feeRecipient = bytes32(uint256(uint160(address(this))));

        bytes32 destinationFeeRecipient = bytes32(uint256(uint160(BOB)));

        (bytes32 messageIdentifier, bytes memory messageWithContext) = setupForAck(address(application), message, destinationFeeRecipient);

        vm.warp(postTime);

        (uint8 v, bytes32 r, bytes32 s) = signMessageForMock(messageWithContext);
        bytes memory mockContext = abi.encode(v, r, s);

        vm.expectEmit();
        emit MessageAcked(messageIdentifier);

        escrow.processPacket(
            mockContext,
            messageWithContext,
            feeRecipient
        );

        // Check that the bounty has been deleted.
        IncentiveDescription memory incentive = escrow.bounty(messageIdentifier);
        assertEq(incentive.refundGasTo, address(0));
    }

    // relayer incentives will be sent here
    receive() payable external {
    }
}