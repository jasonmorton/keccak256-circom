pragma circom 2.0.0;

include "../../circuits/keccak.circom";

component main = Keccak(8192, 32*8);
