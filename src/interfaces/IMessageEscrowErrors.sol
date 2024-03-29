// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IMessageEscrowErrors {
    error NotEnoughGasProvided(uint128 expected, uint128 actual);  // 030748b5
    error MessageAlreadyBountied();  // 068a62ee
    error MessageDoesNotExist();  // 970e41ec
    error MessageAlreadyAcked();  // 8af35858
    error NotImplementedError();  // d41c17e7
    error MessageAlreadySpent();  // e954aba2
    error AckHasNotBeenExecuted();  // 3d1553f8
    error NoImplementationAddressSet();  // 9f994b4b
    error InvalidImplementationAddress();  // c970156c
    error IncorrectValueProvided(uint128 expected, uint128 actual); // 0b52a60b
    error ImplementationAddressAlreadySet(bytes currentImplementation); // dba47850
    error NotEnoughGasExeuction(); // 6fa3d3bb
    error RefundGasToIsZero(); // 6a1a6afe
}