// Keccak256 hash function (ethereum version).
// For LICENSE check https://github.com/vocdoni/keccak256-circom/blob/master/LICENSE

pragma circom 2.0.0;

include "./utils.circom";
include "./permutations.circom";


// Steps
// 0) input is an opaque bit string of size divisible by 8 (may need to be convert e.g. [u8] to little-endian bytes before calling).
// 1) append a little-endian byte 0x01 (bitstring 10000000) to the message M (for domain separation) to get N.
// 2) pad N until it its length in bits is divisible by the rate 1088 to get P with nBlocks blocks P_0,...,P_i,...P_{n-1}.
// 3) bitwise XOR the last 8 bits of P (so the last byte of P_{n-1}) with the byte 0x80 (again in little endian, so 00000001) to obtain Q.
//    - after appending and padding, the last 8 bits of the last block is either 1000000 or 00000000, so this can be an OR for the last block only
//    - this is also expressed in the submission and https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.202.pdf as "multi-rate padding", 10*1, i.e.
//      pad with 1, zero or more 0s, and a final 1 (this would be different if the input bitlength is not a multiple of 8).  Let input message 
//      M have bitlength m. Let j=(-m-2) mod 1088, then append 1, j zeros, and 1. 
// Now we are ready for the sponge phase. We are going to feed each block of size rate=1088 into the state by XORing it in,
// leaving the last 512 bits of untouched, then apply KeccakF1600 to the result to get the new state.
// 4) Initialize the sponge state S to 0 (1600 zeros).
// 5) for each block P_i:
//    - update: S[0..blockSize] = S[0..blockSize] XOR P_i
//    - apply f
// 6) squeeze

template Pad(nBits) {
   signal input in[nBits];
   var i;
   var zeros = ((1088 - (nBits % 1088)) + 1086) % 1088;  // can't just j = (-m-2) % 1088 because negation is in finite field.
   var padsize = 2 + zeros;
   var outlen = nBits+padsize;
   signal output out[outlen];

    for (i=0; i<nBits; i++) {
        out[i] <== in[i]; 
    }

    out[nBits] <== 1;
    out[outlen-1] <== 1;
    for (i=nBits+1; i<outlen-1; i++) {
        out[i] <== 0; 
    } 
}



template KeccakfRound(r) {
    signal input in[25*64];
    signal output out[25*64];
    var i;

    component theta = Theta();
    component rhopi = RhoPi();
    component chi = Chi();
    component iota = Iota(r);

    for (i=0; i<25*64; i++) {
        theta.in[i] <== in[i];
    }
    for (i=0; i<25*64; i++) {
        rhopi.in[i] <== theta.out[i];
    }
    for (i=0; i<25*64; i++) {
        chi.in[i] <== rhopi.out[i];
    }
    for (i=0; i<25*64; i++) {
        iota.in[i] <== chi.out[i];
    }
    for (i=0; i<25*64; i++) {
        out[i] <== iota.out[i];
    }
}

template Absorb() {
    var blockSizeBytes=136;

    signal input s[25*64];                // old state (1600 bits)
    signal input block[blockSizeBytes*8]; // block (1088 bits = 136 bytes) being absorbed
    signal output out[25*64];             // new state (1600 bits)
    var i;
    var j;

    component aux[blockSizeBytes/8];      // array of XorArray components 
    component newS = Keccakf();           // component to compute newstate = KeccakF1600(oldstate)

    for (i=0; i<blockSizeBytes/8; i++) {
        aux[i] = XorArray(64);
        for (j=0; j<64; j++) {
            aux[i].a[j] <== s[i*64+j];
            aux[i].b[j] <== block[i*64+j];
        }
        for (j=0; j<64; j++) {
            newS.in[i*64+j] <== aux[i].out[j];
        }
    }
    // fill the missing s that was not covered by the loop over
    // blockSizeBytes/8
    for (i=(blockSizeBytes/8)*64; i<25*64; i++) {
            newS.in[i] <== s[i];
    }
    for (i=0; i<25*64; i++) {
        out[i] <== newS.out[i];
    }
}

// Consume  nBits<=65536 bits, with nBits % 8 ==0,  and emit 1600-bit state ready for squeezing.
template BigFinal(nBits) {
    signal input in[nBits];   // raw message as bitstring, with nBits % 8 ==0.
    signal output out[25*64]; // output state
    var blockSize = 136*8;
    var i;
    var j;
    var lenPadded = nBits + 2 + (((1088 - (nBits % 1088)) + 1086) % 1088);
    var nBlocks = lenPadded \ 1088;
    signal paddedInput[lenPadded];

    log(nBlocks);

    // Pad the input
    component padder = Pad(nBits);
    for (i=0; i<nBits; i++) {
        padder.in[i] <== in[i];
    }

    component absorbers[nBlocks]; // array of Absorb() components, each will feed state to the next absorber

    // intialize the absorbers
    for (j=0; j<nBlocks; j++) {
	  absorbers[j] = Absorb();
    }
    // initialize the first absorber to 0 state
    for (i=0; i<25*64; i++) {
        absorbers[0].s[i] <== 0; 
    }

    // For all but the last block:
    for (j=0; j<nBlocks-1; j++) {
        // update absorber with the block (starting state already set)
        for (i=0; i<1088; i++) {
	    absorbers[j].block[i] <== padder.out[j*1088 + i]; 
        }
	// send the output state to the next absorber
	for (i=0; i<25*64; i++) {
            absorbers[j+1].s[i] <== absorbers[j].out[i]; 
        }
    }

    //finally do the last block, with index (nBlocks-1)
    // update absorber with the block (starting state already set)
    for (i=0; i<1088; i++) {
        absorbers[nBlocks-1].block[i] <== padder.out[(nBlocks-1)*1088 + i]; 
    }
    // ouput send the output state to the next absorber
    for (i=0; i<25*64; i++) {
        out[i] <== absorbers[nBlocks-1].out[i]; 
    }
}


// Consume up to 1088 bits (one block) and emit state ready for squeezing 
template Final(nBits) {
    signal input in[nBits];   
    signal output out[25*64]; // 
    var blockSize=136*8;
    var i;

    // pad
    component pad = Pad(nBits);
    for (i=0; i<nBits; i++) {
        pad.in[i] <== in[i];
    }
    // absorb
    component abs = Absorb();
    for (i=0; i<blockSize; i++) {
        abs.block[i] <== pad.out[i];  // put in the block
    }
    for (i=0; i<25*64; i++) {
        abs.s[i] <== 0;               // start with sponge at 0 state
    }
    for (i=0; i<25*64; i++) {
        out[i] <== abs.out[i];
    }
}

// Emission function
template Squeeze(nBits) {
    signal input s[25*64];
    signal output out[nBits];
    var i;
    var j;

    for (i=0; i<25; i++) {
        for (j=0; j<64; j++) {
            if (i*64+j<nBits) {
                out[i*64+j] <== s[i*64+j];
            }
        }
    }
}

// State transition function
template Keccakf() {
    signal input in[25*64];
    signal output out[25*64];
    var i;
    var j;

    // 24 rounds
    component round[24];
    signal midRound[24*25*64];
    for (i=0; i<24; i++) {
        round[i] = KeccakfRound(i);
        if (i==0) {
            for (j=0; j<25*64; j++) {
                midRound[j] <== in[j];
            }
        }
        for (j=0; j<25*64; j++) {
            round[i].in[j] <== midRound[i*25*64+j];
        }
        if (i<23) {
            for (j=0; j<25*64; j++) {
                midRound[(i+1)*25*64+j] <== round[i].out[j];
            }
        }
    }

    for (i=0; i<25*64; i++) {
        out[i] <== round[23].out[i];
    }
}


template Keccak(nBitsIn, nBitsOut) {
    signal input in[nBitsIn];
    signal output out[nBitsOut];
    var i;

    component f = BigFinal(nBitsIn);
    for (i=0; i<nBitsIn; i++) {
        f.in[i] <== in[i];
    }
    component squeeze = Squeeze(nBitsOut);
    for (i=0; i<25*64; i++) {
        squeeze.s[i] <== f.out[i];
    }
    for (i=0; i<nBitsOut; i++) {
        out[i] <== squeeze.out[i];
    }
}

//component main { public  [in ]} = Keccak(4096,256);



// template Padding (m) {
//     var j;
//     var i;
//     var mModr = m % 1088;
//     var negmModr = 1088 - mModr;
//     var z = (negmModr + 1086) % 1088;
//     log(z);
//     signal output out[2+z];
    
//     out[0] <== 1;
//     out[2+z-1] <== 1;
//     for (i=1; i<z+1; i++) {
//         out[i] <== 0;
//     }
// }
