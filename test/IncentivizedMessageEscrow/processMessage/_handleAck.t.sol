// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { TestCommon } from "../../TestCommon.t.sol";


contract processPacketAckTest is TestCommon {

    uint256 _receive;

    event Message(
        bytes32 destinationIdentifier,
        bytes recipient,
        bytes message
    );

    function test_ack_process_message() public {
        bytes memory message = _MESSAGE;
        bytes32 feeRecipient = bytes32(uint256(uint160(address(this))));

        bytes32 destinationFeeRecipient = bytes32(uint256(uint160(address(this))));

        (, bytes memory messageWithContext) = setupForAck(address(application), message, destinationFeeRecipient);

        (uint8 v, bytes32 r, bytes32 s) = signMessageForMock(messageWithContext);
        bytes memory mockContext = abi.encode(v, r, s);

        escrow.processPacket(
            mockContext,
            messageWithContext,
            feeRecipient
        );
    }

    function test_ack_called_event() public {
        bytes memory message = _MESSAGE;
        bytes32 feeRecipient = bytes32(uint256(uint160(address(this))));

        bytes32 destinationFeeRecipient = bytes32(uint256(uint160(address(this))));

        (bytes32 messageIdentifier, bytes memory messageWithContext) = setupForAck(address(application), message, destinationFeeRecipient);

        (uint8 v, bytes32 r, bytes32 s) = signMessageForMock(messageWithContext);
        bytes memory mockContext = abi.encode(v, r, s);

        _receive = GAS_RECEIVE_CONSTANT;
        bytes memory _acknowledgement = hex"d9b60178cfb2eb98b9ff9136532b6bd80eeae6a2c90a2f96470294981fcfb62b";

        vm.expectEmit();
        emit MessageAcked(messageIdentifier);

        vm.expectCall(
            address(application),
            abi.encodeCall(
                application.receiveAck,
                (
                    bytes32(0x8000000000000000000000000000000000000000000000000000000000123123),
                    messageIdentifier,
                    _acknowledgement
                )
            )
        );

        escrow.processPacket(
            mockContext,
            messageWithContext,
            feeRecipient
        );

        // Check that the bounty has been deleted.
        IncentiveDescription memory incentive = escrow.bounty(messageIdentifier);
        assertEq(incentive.refundGasTo, address(0));
    }

    function test_ack_different_recipients() public {
        vm.warp(1);
        bytes memory message = _MESSAGE;
        bytes32 feeRecipient = bytes32(uint256(uint160(address(this))));

        bytes32 destinationFeeRecipient = bytes32(uint256(uint160(BOB)));

        (bytes32 messageIdentifier, bytes memory messageWithContext) = setupForAck(address(application), message, destinationFeeRecipient);

        vm.warp(_INCENTIVE.targetDelta + 1);

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

    function test_ack_less_time_than_expected(uint64 timePassed, uint64 targetDelta) public {
        vm.assume(timePassed < targetDelta);
        _INCENTIVE.targetDelta = targetDelta;
        vm.warp(1);
        bytes memory message = _MESSAGE;
        bytes32 feeRecipient = bytes32(uint256(uint160(address(this))));

        bytes32 destinationFeeRecipient = bytes32(uint256(uint160(BOB)));

        (bytes32 messageIdentifier, bytes memory messageWithContext) = setupForAck(address(application), message, destinationFeeRecipient);

        vm.warp(timePassed + 1);

        (uint8 v, bytes32 r, bytes32 s) = signMessageForMock(messageWithContext);
        bytes memory mockContext = abi.encode(v, r, s);

        escrow.processPacket(
            mockContext,
            messageWithContext,
            feeRecipient
        );

        // Check that the bounty has been deleted.
        IncentiveDescription memory incentive = escrow.bounty(messageIdentifier);
        assertEq(incentive.refundGasTo, address(0));
    }

    function test_ack_more_time_than_expected(uint64 timePassed, uint64 targetDelta) public {
        vm.assume(targetDelta < type(uint64).max/2);
        vm.assume(timePassed > targetDelta);
        vm.assume(timePassed - targetDelta < targetDelta);
        _INCENTIVE.targetDelta = targetDelta;
        vm.warp(1);
        bytes memory message = _MESSAGE;
        bytes32 feeRecipient = bytes32(uint256(uint160(address(this))));

        bytes32 destinationFeeRecipient = bytes32(uint256(uint160(BOB)));

        (bytes32 messageIdentifier, bytes memory messageWithContext) = setupForAck(address(application), message, destinationFeeRecipient);

        vm.warp(timePassed + 1);

        (uint8 v, bytes32 r, bytes32 s) = signMessageForMock(messageWithContext);
        bytes memory mockContext = abi.encode(v, r, s);

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