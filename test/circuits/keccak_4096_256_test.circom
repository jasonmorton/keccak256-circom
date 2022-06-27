pragma circom 2.0.0;

include "../../circuits/keccak.circom";

component main = Keccak(4096, 32*8);
