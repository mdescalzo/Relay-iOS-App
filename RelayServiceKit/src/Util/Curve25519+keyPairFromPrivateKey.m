//
//  Curve25519+keyPairFromPrivateKey.m
//  Forsta
//
//  Created by Mark Descalzo on 5/10/18.
//  Copyright © 2018 Forsta. All rights reserved.
//

#import "Curve25519+keyPairFromPrivateKey.h"

extern void curve25519_donna(unsigned char *output, const unsigned char *a, const unsigned char *b);

extern int  curve25519_sign(unsigned char* signature_out, /* 64 bytes */
                            const unsigned char* curve25519_privkey, /* 32 bytes */
                            const unsigned char* msg, const unsigned long msg_len,
                            const unsigned char* random); /* 64 bytes */

@implementation ECKeyPair (keyPairFromPrivateKey)

+(ECKeyPair*)generateKeyPairWithPrivateKey:(NSData *)privKey
{
    ECKeyPair* keyPair = [Curve25519 generateKeyPair];
    
    // Generate key pair as described in
    // https://code.google.com/p/curve25519-donna/
    uint8_t *privateKeyBytes = privKey.bytes;
    privateKeyBytes[0] &= 248;
    privateKeyBytes[31] &= 127;
    privateKeyBytes[31] |= 64;
    
    static const uint8_t basepoint[ECCKeyLength] = { 9 };
    
    curve25519_donna(keyPair.publicKey.bytes, keyPair.privateKey.bytes, basepoint);

    return keyPair;
    
//    // Generate key pair as described in https://code.google.com/p/curve25519-donna/
//    memcpy(keyPair->privateKey, privKey.bytes, 32);
//    keyPair->privateKey[0]  &= 248;
//    keyPair->privateKey[31] &= 127;
//    keyPair->privateKey[31] |= 64;
//
//    static const uint8_t basepoint[ECCKeyLength] = {9};
//    curve25519_donna(keyPair.publicKey, keyPair.privateKey, basepoint);
//    return keyPair;
}

@end


@implementation Curve25519 (keyPairFromPrivateKey)

+ (ECKeyPair *)generateKeyPairWithPrivateKey:(NSData *)privKey
{
    return [ECKeyPair generateKeyPairWithPrivateKey:privKey];
}


@end
