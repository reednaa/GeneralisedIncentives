// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { TestCommon } from "../../TestCommon.t.sol";

contract EscrowInformationTest is TestCommon {
    uint256 _overpay;

    function test_check_escrow_state() public {
        IncentiveDescription storage incentive = _INCENTIVE;
        (, bytes32 messageIdentifier) = escrow.submitMessage{value: _getTotalIncentive(_INCENTIVE)}(
            bytes32(uint256(0x123123) + uint256(2**255)),
            _DESTINATION_ADDRESS_THIS,
            _MESSAGE,
            incentive
        );

        // Check that the message identifier points exposes the bounty.
        IncentiveDescription memory storedIncentiveAtEscrow = escrow.bounty(messageIdentifier);

        assertEq(incentive.maxGasDelivery, storedIncentiveAtEscrow.maxGasDelivery);
        assertEq(incentive.maxGasAck, storedIncentiveAtEscrow.maxGasAck);
        assertEq(incentive.refundGasTo, storedIncentiveAtEscrow.refundGasTo);
        assertEq(incentive.priceOfDeliveryGas, storedIncentiveAtEscrow.priceOfDeliveryGas);
        assertEq(incentive.priceOfAckGas, storedIncentiveAtEscrow.priceOfAckGas);
        assertEq(incentive.targetDelta, storedIncentiveAtEscrow.targetDelta);
    }

    function test_check_escrow_events() public {
        IncentiveDescription storage incentive = _INCENTIVE;

        vm.expectEmit();
        emit BountyPlaced(bytes32(0xb9ca07b4390ffb7693876d025f356c92a2a0502b46c9cd4ad0aecb195774ec98), incentive);

        escrow.submitMessage{value: _getTotalIncentive(_INCENTIVE)}(
            bytes32(uint256(0x123123) + uint256(2**255)),
            _DESTINATION_ADDRESS_THIS,
            _MESSAGE,
            incentive
        );
    }

    function test_gas_refund(uint256 overpay) public {
        vm.assume(overpay < 10000 ether);

        IncentiveDescription storage incentive = _INCENTIVE;
        _overpay = overpay;

        
        (uint256 gasRefund, ) = escrow.submitMessage{value: _getTotalIncentive(_INCENTIVE) + overpay}(
            bytes32(uint256(0x123123) + uint256(2**255)),
            _DESTINATION_ADDRESS_THIS,
            _MESSAGE,
            incentive
        );

        assertEq(gasRefund, overpay);
    }

    // test_gas_refund will end up calling this function.
    receive() payable external {
        assertNotEq(msg.value, 0);
        assertEq(msg.value, _overpay);
    }
}
