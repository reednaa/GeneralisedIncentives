// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { IIncentivizedMessageEscrow } from "./interfaces/IIncentivizedMessageEscrow.sol";
import { ICrossChainReceiver } from "./interfaces/ICrossChainReceiver.sol";
import { Bytes65 } from "./utils/Bytes65.sol";
import { CTX_SOURCE_TO_DESTINATION, CTX_DESTINATION_TO_SOURCE } from "./MessagePayload.sol";
import { Multicall } from "openzeppelin/utils/Multicall.sol";
import "./MessagePayload.sol";


/**
 * @title Generalised Incentive Escrow
 * @author Alexander @ Catalyst
 * @notice Places transparent incentives on relaying messages.
 * This contract is intended to sit between an application and a cross-chain message protocol.
 * The goal is to overload the existing incentive scheme with one which is open for anyone.
 *
 * Each messaging protocol will have a respective implementation which understands
 * how to send and verify messages. An integrating application shall deliver a message to submitMessage
 * along with the respective incentives. This contract will then handle transfering the message to the
 * destination and carry an ack back from the destination to return to the integrating application.
 *
 * The incentive is released when an ack from the destination chain is delivered to this contract.
 *
 * Beyond making relayer incentives strong, this contract also implements several quality of life features:
 * - Refund unused gas.
 * - Seperate gas payments for call and ack.
 * - Simple implementation of new messaging protocols.
 */
abstract contract IncentivizedMessageEscrow is IIncentivizedMessageEscrow, Bytes65, Multicall {
    
    //--- Constants ---//

    /// @notice  If a swap reverts on the destination chain, 1 bytes is sent back instead. This is the byte.
    bytes1 constant public MESSAGE_REVERTED = 0xff;

    /// @notice  If the original sender is not authorised on the application on the destination chain, 1 bytes is sent back instead. This is the byte.
    bytes1 constant public NO_AUTHENTICATION = 0xfe;

    /// @notice If a relayer or application provides an address which cannot accept gas and the transfer fails
    /// the gas is sent here instead.
    address immutable public SEND_LOST_GAS_TO;

    //--- Storage ---//
    mapping(bytes32 => IncentiveDescription) _bounty;

    mapping(bytes32 => bool) _messageDelivered;

    // Maps applications to their escrow implementations.
    mapping(address => mapping(bytes32 => bytes)) public implementationAddress;
    mapping(address => mapping(bytes32 => bytes32)) public implementationAddressHash;
    //--- Virtual Functions ---//
    // To integrate a messaging protocol, a contract has to inherit this contract and implement the below 3 functions.

    /// @notice Verify a message's authenticity.
    /// @dev Should be overwritten by the specific messaging protocol verification structure.
    function _verifyPacket(bytes calldata messagingProtocolContext, bytes calldata rawMessage) virtual internal returns(bytes32 sourceIdentifier, bytes memory destinationIdentifier, bytes calldata message);

    /// @notice Send the message to the messaging protocol.
    /// @dev Should be overwritten to send a message using the specific messaging protocol.
    /// If there is an additional cost to emitting messages, this cost should be caled on the function and returned
    /// as costOfsendPacketInNativeToken. The function is allowed to take ERC20 tokens (transferFrom(msg.sender,...)) in which case 
    /// costOfsendPacketInNativeToken should be set to 0.
    function _sendPacket(bytes32 destinationIdentifier, bytes memory destinationImplementation, bytes memory message) virtual internal returns(uint128 costOfsendPacketInNativeToken);

    /// @param sendLostGasTo Who should receive Ether which would otherwise block
    /// execution? It should never be set to a contract which does not implement
    /// either a fallback or receive function which never revert.
    /// It can be set to address 0 or a similar burn address if no-one wants to take ownership of the ether.
    constructor(address sendLostGasTo) {
        SEND_LOST_GAS_TO = sendLostGasTo;
    }

    /**
     * @notice Generates a unique message identifier for a message
     * @dev Should be overwritten. The identifier should:
     *  - Be unique over time: Use blocknumber or blockhash
     *  - Be unique on destination chain: Use a unique source identifier 
     *  - Be unique on the source chain: Use a unique destinationIdentifier
     *  - Depend on the message
     *  - Depend on the sender such that applications can't be dosed. 
     *  This also implies that application should make their messages user specific.
     */
    function _getMessageIdentifier(
        bytes32 destinationIdentifier,
        bytes calldata message
    ) view internal virtual returns(bytes32);

    //--- Getter Functions ---//
    function bounty(bytes32 messageIdentifier) external view returns(IncentiveDescription memory incentive) {
        return _bounty[messageIdentifier];
    }

   function messageDelivered(bytes32 messageIdentifier) external view returns(bool hasMessageBeenExecuted) {
        return _messageDelivered[messageIdentifier];
   }


    /// @notice Sets the escrow implementation for a specific chain
    /// @dev This can only be set once. When set, is cannot be changed.
    /// This is to protect relayers as this could be used to fail acks.
    function setRemoteImplementation(bytes32 destinationIdentifier, bytes calldata implementation) external {
        if (implementationAddressHash[msg.sender][destinationIdentifier] != bytes32(0)) revert ImplementationAddressAlreadySet(
            implementationAddress[msg.sender][destinationIdentifier]
        );

        implementationAddress[msg.sender][destinationIdentifier] = implementation;
        implementationAddressHash[msg.sender][destinationIdentifier] = keccak256(implementation);

        emit RemoteImplementationSet(msg.sender, destinationIdentifier, keccak256(implementation), implementation);
    }

    //--- Public Endpoints ---//

    /**
     * @notice Increases the bounty for relaying messages
     * @dev It is not possible to increase the gas budget for a message. 
     */
    function increaseBounty(
        bytes32 messageIdentifier,
        uint96 deliveryGasPriceIncrease,
        uint96 ackGasPriceIncrease
    ) external payable {
        if (_bounty[messageIdentifier].refundGasTo == address(0)) revert MessageDoesNotExist();
        // Find incentive scheme.
        IncentiveDescription storage incentive = _bounty[messageIdentifier];

        // Compute incentive metrics.
        uint128 maxDeliveryFee = incentive.maxGasDelivery * deliveryGasPriceIncrease;
        uint128 maxAckFee = incentive.maxGasAck * ackGasPriceIncrease;
        uint128 sum = maxDeliveryFee + maxAckFee;
        // Check that the provided gas is exact
        if (msg.value != sum) revert IncorrectValueProvided(sum, uint128(msg.value));

        uint96 newPriceOfDeliveryGas = incentive.priceOfDeliveryGas + deliveryGasPriceIncrease;
        uint96 newPriceOfAckGas = incentive.priceOfAckGas + ackGasPriceIncrease;
        // Update storage.
        incentive.priceOfDeliveryGas = newPriceOfDeliveryGas;
        incentive.priceOfAckGas = newPriceOfAckGas;

        // Emit the event with the increased values.
        emit BountyIncreased(
            messageIdentifier,
            newPriceOfDeliveryGas,
            newPriceOfAckGas
        );
    }

    /** 
     * @notice Set a bounty on a message and transfer the message to the messaging protocol.
     * @dev Called by other contracts.
     * Any integrating application should check:
     *     1. That incentive.maxGasAck is sufficient! Otherwise, an off-chain agent needs to re-submit the ack.
     *     2. That incentive.maxGasDelivery is sufficient. Otherwise, the call will fail within the try - catch.
     *     3. The relay incentive is enough to get the message relayed within the expected time. If that is never, this check is not needed.
     * @param destinationIdentifier 32 bytes which identifies the destination chain.
     * @param destinationAddress The destination address encoded in 65 bytes: First byte is the length and last 64 is the destination address.
     * @param message The message to be sent to the destination. Please ensure the message is block-unique.
     *     This means that you don't send the same message twice in a single block.
     * @return gasRefund The amount of excess gas which was paid to this call. The app should handle the excess.
     * @return messageIdentifier An unique identifier for a message.
     */
    function submitMessage(
        bytes32 destinationIdentifier,
        bytes calldata destinationAddress,
        bytes calldata message,
        IncentiveDescription calldata incentive
    ) checkBytes65Address(destinationAddress) external payable returns(uint256 gasRefund, bytes32 messageIdentifier) {
        if (incentive.refundGasTo == address(0)) revert RefundGasToIsZero();
        // Check that the application has set a destination implementation
        bytes memory destinationImplementation = implementationAddress[msg.sender][destinationIdentifier];
        // Check that the length is not 0.
        if (destinationImplementation.length == 0) revert NoImplementationAddressSet();

        // Prepare to store incentive
        messageIdentifier = _getMessageIdentifier(
            destinationIdentifier,
            message
        );
        // Store the bounty, get the sum for later refunding excess.
        uint128 sum = _setBounty(messageIdentifier, incentive);

        // Add escrow context to the message.
        bytes memory messageWithContext = abi.encodePacked(
            bytes1(CTX_SOURCE_TO_DESTINATION),    // This is a sendPacket,
            messageIdentifier,              // A unique message identifier
            convertEVMTo65(msg.sender),     // Original sender
            destinationAddress,             // The address to deliver the (original) message to.
            incentive.maxGasDelivery,       // Send the gas limit to the other chain so we can enforce it
            message                         // The message to deliver to the destination.
        );

        // Emit the event for off-chain relayers.
        emit BountyPlaced(
            messageIdentifier,
            incentive
        );

        // Bounty is emitted before event to standardized with the other event before sending message scheme.

        // Send message to messaging protocol
        // This call will collect payments for sending the message. It can be in any token but if it is in 
        // native gas, it should return the amount it took.
        uint128 costOfsendPacketInNativeToken = _sendPacket(
            destinationIdentifier,
            destinationImplementation,
            messageWithContext
        );
        // Add the cost of the send message.
        sum += costOfsendPacketInNativeToken;

        // Check that the provided gas is sufficient. The refund will be sent later.
        if (msg.value < sum) revert NotEnoughGasProvided(sum, uint128(msg.value));


        // Return excess incentives to the user (found from incentive.refundGasTo).
        unchecked {
            if (msg.value > sum) {
                // We know: msg.value >= sum, thus msg.value - sum >= 0.
                gasRefund = msg.value - sum;
                payable(incentive.refundGasTo).transfer(gasRefund);
                return (gasRefund, messageIdentifier);
            }
        }
        return (0, messageIdentifier);
    }

    /**
     * @notice Deliver a message which has been *signed* by a messaging protocol.
     * @dev This function is intended to be called by off-chain agents.
     *  Please ensure that feeRecipient can receive gas token: Either it is an EOA or a implement fallback() / receive().
     *  Likewise for any non-evm chains. Otherwise the message fails (ack) or the relay payment is lost (call).
     *  You need to pass in incentive.maxGas(Delivery|Ack) + messaging protocol dependent buffer, otherwise this call might fail.
     * On Receive implementations make _verifyPacket revert. The result is
     * that this endpoint is disabled.
     * @param messagingProtocolContext Additional context required to verify the message by the messaging protocol.
     * @param rawMessage The raw message as it was emitted.
     * @param feeRecipient An identifier for the the fee recipient. The identifier should identify the relayer on the source chain.
     *  For EVM (and this contract as a source), use the bytes32 encoded address. For other VMs you might have to register your address.
     */
    function processPacket(
        bytes calldata messagingProtocolContext,
        bytes calldata rawMessage,
        bytes32 feeRecipient
    ) external virtual payable {
        uint256 gasLimit = gasleft();  // uint256 is used here instead of uint48, since there is no advantage to uint48 until after we calculate the difference.

        // Verify that the message is authentic and remove potential context that the messaging protocol added to the message.
        (bytes32 chainIdentifier, bytes memory implementationIdentifier, bytes calldata message) = _verifyPacket(messagingProtocolContext, rawMessage);

        // Figure out if this is a call or an ack.
        bytes1 context = bytes1(message[0]);
        if (context == CTX_SOURCE_TO_DESTINATION) {
            bytes memory receiveAckWithContext = _handleMessage(chainIdentifier, implementationIdentifier, message, feeRecipient, gasLimit);

            // The cost management is made by _sendPacket so we don't have to check if enough gas has been provided.
            _sendPacket(chainIdentifier, implementationIdentifier, receiveAckWithContext);
        } else if (context == CTX_DESTINATION_TO_SOURCE) {
            _handleAck(chainIdentifier, implementationIdentifier, message, feeRecipient, gasLimit);
        } else {
            revert NotImplementedError();
        }
    }

    //--- Internal Functions ---//

    /**
     * @notice Handles call messages.
     */
    function _handleMessage(bytes32 sourceIdentifier, bytes memory sourceImplementationIdentifier, bytes calldata message, bytes32 feeRecipient, uint256 gasLimit) internal returns(bytes memory receiveAckWithContext) {
        // Ensure message is unique and can only be execyted once
        bytes32 messageIdentifier = bytes32(message[MESSAGE_IDENTIFIER_START:MESSAGE_IDENTIFIER_END]);

        // The 3 next lines act as a reentry guard, so this call doesn't have to be protected by reentry.
        bool messageState = _messageDelivered[messageIdentifier];
        if (messageState) revert MessageAlreadySpent();
        _messageDelivered[messageIdentifier] = true;


        // Deliver message to application.
        // Decode gas limit, application address and sending application.
        uint48 maxGas = uint48(bytes6(message[CTX0_MAX_GAS_LIMIT_START:CTX0_MAX_GAS_LIMIT_END]));
        address toApplication = address(bytes20(message[CTX0_TO_APPLICATION_START_EVM:CTX0_TO_APPLICATION_END])); 
        bytes calldata fromApplication = message[FROM_APPLICATION_LENGTH_POS:FROM_APPLICATION_END];

        bytes memory acknowledgement;

        bytes32 expectedSourceImplementationHash = implementationAddressHash[toApplication][sourceIdentifier];
        // Check that the application allows the source implementation.
        // This is not the case when another implementation calls this contract from the source chain.
        // Since this could be a mistake, send back an ack with the relevant information.
        if (expectedSourceImplementationHash != keccak256(sourceImplementationIdentifier)) {
            // If they are different, return send a failed message back with `0xfe`.
            acknowledgement = abi.encodePacked(
                NO_AUTHENTICATION,
                message[CTX0_MESSAGE_START: ]
            );
        } else {
            // Execute call to application. Gas limit is set explicitly to ensure enough gas has been sent.

            // This call might fail because the abi.decode of the return value can fail. It is too gas costly to check all correctness 
            // of the returned value and then error if decoding is not possible.
            // As a result, relayers needs to simulate the tx. If the call fails, then they should blacklist the message.
            // The call will only fall if the application doesn't expose receiveMessage or captures the message via a fallback. 
            // As a result, if message delivery once executed, then it will always execute.
            try ICrossChainReceiver(toApplication).receiveMessage{gas: maxGas}(sourceIdentifier, messageIdentifier, fromApplication, message[CTX0_MESSAGE_START: ])
            returns (bytes memory ack) {
                acknowledgement = ack;
            } catch (bytes memory /* err */) {
                // Check that enough gas was provided to the application. For further documentation of this statement, check
                // the long description on ack. TLDR: The relayer can cheat the application by providing less gas
                // but this statement ensures that if they try to do that, then it will fail (assuming the application reverts).
                if(gasleft() < maxGas * 1 / 63) revert NotEnoughGasExeuction();

                // Send the message back if the execution failed.
                // This lets you store information in the message that you can trust 
                // gets returned. (You just have to understand that the status is appended as the first byte.)
                acknowledgement = abi.encodePacked(
                    MESSAGE_REVERTED,
                    message[CTX0_MESSAGE_START: ]
                );
            }
        }

    
        // Encode a new message to send back. This lets the relayer claim their payment.
        receiveAckWithContext = abi.encodePacked(
            bytes1(CTX_DESTINATION_TO_SOURCE),    // This is a sendPacket
            messageIdentifier,              // message identifier
            fromApplication,
            feeRecipient,
            uint48(gasLimit - gasleft()),   // Delay the gas limit computation until as late as possible. This should include the majority of gas spent.
            uint64(block.timestamp),        // If this overflows, it is fine. It is used in conjunction with a delta.
            acknowledgement
        );

        // Message has been delivered and shouldn't be executed again.
        emit MessageDelivered(messageIdentifier);

        // Why is the messageDelivered event emitted before _sendPacket?
        // Because it lets us pop messageIdentifier from the stack. This avoid a stack limit reached error. 
        // Not optimal but okay-ish.

        // Send message to messaging protocol
        // This is done on processPacket.
        // This is done by returning receiveAckWithContext while source identifier and sourceImplementationIdentifier are known.
    }

    /**
     * @notice Handles ack messages.
     */
    function _handleAck(bytes32 destinationIdentifier, bytes memory destinationImplementationIdentifier, bytes calldata message, bytes32 feeRecipient, uint256 gasLimit) internal {
        // Ensure the bounty can only be claimed once.
        bytes32 messageIdentifier = bytes32(message[MESSAGE_IDENTIFIER_START:MESSAGE_IDENTIFIER_END]);

        // The 3 (9, loading the variables out of storage fills a bit.) next lines act as a reentry guard,
        // so this call doesn't have to be protected by reentry.
        IncentiveDescription storage incentive = _bounty[messageIdentifier];
        // Load all variables from storage onto the stack.
        uint48 maxGasDelivery = incentive.maxGasDelivery;
        uint48 maxGasAck = incentive.maxGasAck;
        address refundGasTo = incentive.refundGasTo;
        uint96 priceOfDeliveryGas = incentive.priceOfDeliveryGas;
        uint96 priceOfAckGas = incentive.priceOfAckGas;
        uint64 targetDelta = incentive.targetDelta;
        if (refundGasTo == address(0)) revert MessageAlreadyAcked();
        delete _bounty[messageIdentifier];  // The bounty cannot be accessed anymore.

        address fromApplication = address(bytes20(message[FROM_APPLICATION_START_EVM:FROM_APPLICATION_END]));

        // First check if the application trusts the implementation on the destination chain.
        bytes32 expectedDestinationImplementationHash = implementationAddressHash[fromApplication][destinationIdentifier];
        // Check that the application approves the source implementation
        // For acks, this should always be the case except when a fradulent applications sends a message to this contract.
        if (expectedDestinationImplementationHash != keccak256(destinationImplementationIdentifier)) revert InvalidImplementationAddress();

        // Deliver the ack to the application.
        // Ensure that if the call reverts it doesn't boil up.
        // We don't need any return values and don't care if the call reverts.
        // This call implies we need reentry protection.
        bytes memory payload = abi.encodeWithSignature("receiveAck(bytes32,bytes32,bytes)", destinationIdentifier, messageIdentifier, message[CTX1_MESSAGE_START: ]);
        bool success;
        assembly ("memory-safe") {
            // Because Solidity always create RETURNDATACOPY for external calls, even low-level calls where no variables are assigned,
            // the contract can be attacked by a so called return bomb. This incur additional cost to the relayer they aren't paid for.
            // To protect the relayer, the call is made in inline assembly.
            success := call(maxGasAck, fromApplication, 0, add(payload, 0x20), mload(payload), 0, 0)
            // This is what the call would look like non-assembly.
            // fromApplication.call{gas: maxGasAck}(
            //     abi.encodeWithSignature("receiveAck(bytes32,bytes32,bytes)", destinationIdentifier, messageIdentifier, message[CTX1_MESSAGE_START: ])
            // );

        }
        // External calls are allocated gas according roughly the following: min( gasleft * 63/64, gasArg ).
        // If there is no check against gasleft, then a relayer could potentially cheat by providing less gas.
        // Without a check, they only have to provide enough gas such that any further logic executees on 1/64 of gasleft
        // To ensure maximum compatibility with external tx simulation and gas estimation tools we will check a more complex
        // but more forgiving expression.
        // Before the call, there needs to be at least maxGasAck * 64/63 gas available. With that available, then
        // the call is allocated exactly min((maxGasAck * 64/63) * 63/64 >= , maxGasAck) = maxGasAck.
        // If the call uses up all of the gas, then there must be maxGasAck * 64/63 - maxGasAck = maxGasAck * 1/63
        // gas left. It is sufficient to check that smaller limit rather than the larger limit.
        // Furthermore, if we only check when the call failed we don't have to read gasleft if it is not needed.
        unchecked {
            if (!success) if(gasleft() < maxGasAck * 1 / 63) revert NotEnoughGasExeuction();
        }
        // Why is this better (than checking before)?
        // 1. We only have to check when the call failed. The vast majority of acks should not revert so it won't be checked.
        // 2. For the majority of applications it is going to be hold that: gasleft > rest of logic > maxGasAck * 1 / 63
        // and as such won't impact and execution/gas simuatlion/estimation libs.
        
        // Why is this worse?
        // 1. What if the application expected us to check that it got maxGasAck? It might assume that it gets
        // maxGasAck, when it turns out it got less it silently reverts (say by a low level call ala ours).

        // Get the gas used by the destination call.
        uint256 gasSpentOnDestination = uint48(bytes6(message[CTX1_GAS_SPENT_START:CTX1_GAS_SPENT_END]));

        // Find the respective rewards for delivery and ack.
        uint256 deliveryFee; uint256 ackFee; uint256 actualFee; uint256 refund; uint256 gasSpentOnSource;
        unchecked {
            // gasSpentOnDestination * priceOfDeliveryGas < 2**48 * 2**96 = 2**144
            if (maxGasDelivery <= gasSpentOnDestination) gasSpentOnDestination = maxGasDelivery;  // If more gas was spent then allocated, then only use the allocation.
            deliveryFee = gasSpentOnDestination * priceOfDeliveryGas;  
            // Delay the gas limit computation until as late as possible. This should include the majority of gas spent.
            // gasLimit = gasleft() when less gas was spent, thus it is always larger than gasleft().
            gasSpentOnSource = gasLimit - gasleft();
            if (maxGasAck <= gasSpentOnSource) gasSpentOnSource = maxGasAck;  // If more gas was spent then allocated, then only use the allocation.
            // gasSpentOnSource * priceOfAckGas < 2**48 * 2**96 = 2**144
            ackFee = gasSpentOnSource * priceOfAckGas;  
            // deliveryFee + ackFee < 2**144 + 2**144 = 2**145
            actualFee = deliveryFee + ackFee;
            // (priceOfDeliveryGas * maxGasDelivery + priceOfDeliveryGas * maxGasAck) has been caculated before (escrowBounty) < (2**48 * 2**96) + (2**48 * 2**96) = 2**144 + 2**144 = 2**145
            uint256 maxDeliveryFee = maxGasDelivery * priceOfDeliveryGas;
            uint256 maxAckFee = maxGasAck * priceOfAckGas;
            uint256 maxFee = maxDeliveryFee + maxAckFee;
            refund = maxFee - actualFee;
        }
        // send is used to ensure this doesn't revert. Transfer could revert and block the ack from ever being delivered.
        if(!payable(refundGasTo).send(refund)) {
            payable(SEND_LOST_GAS_TO).transfer(refund);  // If we don't send the gas somewhere, the gas is lost forever.
        }
        address destinationFeeRecipient = address(uint160(uint256(bytes32(message[CTX1_RELAYER_RECIPIENT_START:CTX1_RELAYER_RECIPIENT_END]))));
        address sourceFeeRecipient = address(uint160(uint256(feeRecipient)));
        // If both the destination relayer and source relayer are the same then we don't have to figure out which fraction goes to who.
        if (destinationFeeRecipient == sourceFeeRecipient) {
            payable(sourceFeeRecipient).transfer(actualFee);  // If this reverts, then the relayer that is executing this tx provided a bad input.
            emit MessageAcked(messageIdentifier);
            emit BountyClaimed(
                messageIdentifier,
                uint64(gasSpentOnDestination),
                uint64(gasSpentOnSource),
                uint128(actualFee),
                0
            );
            return;
        }

        // If targetDelta is 0, then distribute exactly the rewards.
        if (targetDelta == 0) {
            // ".send" is used to ensure this doesn't revert. ".transfer" could revert and block the ack from ever being delivered.
            if(!payable(destinationFeeRecipient).send(deliveryFee)) {  // If this returns false, it implies that the transfer failed.
                // The result is that this contract still has deliveryFee. As a result, send it somewhere else.
                payable(SEND_LOST_GAS_TO).transfer(deliveryFee);  // If we don't send the gas somewhere, the gas is lost forever.
            }
            payable(sourceFeeRecipient).transfer(ackFee);  // If this reverts, then the relayer that is executing this tx provided a bad input.
            emit MessageAcked(messageIdentifier);
            emit BountyClaimed(
                messageIdentifier,
                uint64(gasSpentOnDestination),
                uint64(gasSpentOnSource),
                uint128(deliveryFee),
                uint128(ackFee)
            );
            return;
        }
        // Compute the reward distribution. We need the time it took to deliver the ack back.
        uint64 executionTime;
        unchecked {
            // Underflow is desired in this code chuck. It ensures that the code piece continues working
            // past the time when uint64 stops working. *As long as any timedelta is less than uint64.
            executionTime = uint64(block.timestamp) - uint64(bytes8(message[CTX1_EXECUTION_TIME_START:CTX1_EXECUTION_TIME_END]));
        }
        // The incentive scheme is as follows: When executionTime = targetDelta then 
        // The rewards are distributed as per the incentive spec. If the time is less, then
        // more incentives are given to the destination relayer while if the time is more, 
        // then more incentives are given to the sourceRelayer.
        uint256 forDestinationRelayer = deliveryFee;
        unchecked {
            // |targetDelta - executionTime| < |2**64 + 2**64| = 2**65
            int256 timeBetweenTargetAndExecution = int256(uint256(executionTime))-int256(uint256(targetDelta));
            if (timeBetweenTargetAndExecution <= 0) {
                // Less time than target passed and the destination relayer should get a larger chunk.
                // targetDelta != 0, we checked for that. 
                // max abs timeBetweenTargetAndExecution = | - targetDelta| = targetDelta => ackFee * targetDelta < actualFee * targetDelta
                //  2**127 * 2**64 = 2**191
                forDestinationRelayer += ackFee * uint256(- timeBetweenTargetAndExecution) / targetDelta;
            } else {
                // More time than target passed and the ack relayer should get a larger chunk.
                // If more time than double the target passed, the ack relayer should get everything
                if (uint256(timeBetweenTargetAndExecution) < targetDelta) {
                    // targetDelta != 0, we checked for that. 
                    // max abs timeBetweenTargetAndExecution = targetDelta since we have the above check
                    // => deliveryFee * targetDelta < actualFee * targetDelta < 2**127 * 2**64 = 2**191
                    forDestinationRelayer -= deliveryFee * uint256(timeBetweenTargetAndExecution) / targetDelta;
                } else {
                    // This doesn't discourage relaying, since executionTime first begins counting once the destination call has been executed.
                    // As a result, this only encourages delivery of the ack.
                    forDestinationRelayer = 0;
                }
            }
        }
        // send is used to ensure this doesn't revert. Transfer could revert and block the ack from ever being delivered.
        if(!payable(destinationFeeRecipient).send(forDestinationRelayer)) {
            payable(SEND_LOST_GAS_TO).transfer(forDestinationRelayer);  // If we don't send the gas somewhere, the gas is lost forever.
        }
        uint256 forSourceRelayer;
        unchecked {
            // max forDestinationRelayer is deliveryFee + ackFee = actualFee => actualFee - forDestinationRelayer == 0
            // min forDestinationRelayer = 0 => actualFee - 0 = actualFee
            forSourceRelayer = actualFee - forDestinationRelayer;
        }
        payable(sourceFeeRecipient).transfer(forSourceRelayer);  // If this reverts, then the relayer that is executing this tx provided a bad input.

        emit MessageAcked(messageIdentifier);
        emit BountyClaimed(
            messageIdentifier,
            uint64(gasSpentOnDestination),
            uint64(gasSpentOnSource),
            uint128(forDestinationRelayer),
            uint128(forSourceRelayer)
        );
    }


    /// @notice Sets a bounty for a message
    /// @dev Doesn't check if enough incentives have been provided.
   function _setBounty(
        bytes32 messageIdentifier, 
        IncentiveDescription calldata incentive
    ) internal returns(uint128 sum){
        if (_bounty[messageIdentifier].refundGasTo != address(0)) revert MessageAlreadyBountied();
        // Compute incentive metrics.
        uint128 maxDeliveryFee = incentive.maxGasDelivery * incentive.priceOfDeliveryGas;
        uint128 maxAckFee = incentive.maxGasAck * incentive.priceOfAckGas;
        sum = maxDeliveryFee + maxAckFee;
        
        _bounty[messageIdentifier] = incentive;
    }


    /// @notice Allows anyone to re-execute an ack which didn't properly execute.
    /// @dev No applciation should rely on this function. It should only be used in-case an
    /// application has faulty logic. 
    /// Example: Faulty logic results in wrong enforcement on gas limit => out of gas?
    function recoverAck(
        bytes calldata messagingProtocolContext,
        bytes calldata rawMessage
    ) external {
        (bytes32 chainIdentifier,  bytes memory implementationIdentifier, bytes calldata message) = _verifyPacket(messagingProtocolContext, rawMessage);

        bytes1 context = bytes1(message[0]);
        
        // Only allow acks to do this. Normal messages are invalid after first execution.
        if (context == CTX_DESTINATION_TO_SOURCE) {
            bytes32 messageIdentifier = bytes32(message[MESSAGE_IDENTIFIER_START:MESSAGE_IDENTIFIER_END]);
            if(_bounty[messageIdentifier].refundGasTo != address(0)) revert AckHasNotBeenExecuted(); 

            address fromApplication = address(bytes20(message[FROM_APPLICATION_START_EVM:FROM_APPLICATION_END]));

            
            // check if the application trusts the implementation on the destination chain.
            bytes32 expectedDestinationImplementationHash = implementationAddressHash[fromApplication][chainIdentifier];
            if (expectedDestinationImplementationHash != keccak256(implementationIdentifier)) revert InvalidImplementationAddress();

            ICrossChainReceiver(fromApplication).receiveAck(chainIdentifier, messageIdentifier, message[CTX1_MESSAGE_START: ]);

            emit MessageAcked(messageIdentifier);
        } else {
            revert NotImplementedError();
        }
    }
}
