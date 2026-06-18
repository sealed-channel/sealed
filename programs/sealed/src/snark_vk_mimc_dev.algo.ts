// AUTO-GENERATED from circuits/keys/vk_mimc_dev.json by circuits/scripts/gen-vk-bytes.mjs
// DO NOT EDIT. Regenerate with: cd circuits && node scripts/gen-vk-bytes.mjs
// Tag: MIMC_DEV    Curve: BN254 (bn128)    nPublic: 4
//
// Byte layout (AVM EC opcodes, BN254):
//   G1 = X(32B) || Y(32B)
//   G2 = X0(32B) || X1(32B) || Y0(32B) || Y1(32B)

import { Bytes, bytes, uint64 } from '@algorandfoundation/algorand-typescript'

export const SNARK_VK_TAG = 'MIMC_DEV' as const

export const VK_ALPHA_1: bytes = Bytes.fromHex('2d4d9aa7e302d9df41749d5507949d05dbea33fbb16c643b22f599a2be6df2e214bedd503c37ceb061d8ec60209fe345ce89830a19230301f076caff004d1926')
export const VK_BETA_2: bytes  = Bytes.fromHex('0e187847ad4c798374d0d6732bf501847dd68bc0e071241e0213bc7fc13db7ab0967032fcbf776d1afc985f88877f182d38480a653f2decaa9794cbc3bf3060c1739c1b1a457a8c7313123d24d2f9192f896b7c63eea05a9d57f06547ad0cec8304cfbd1e08a704a99f5e847d93f8c3caafddec46b7a0d379da69a4d112346a7')
export const VK_GAMMA_2: bytes = Bytes.fromHex('1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c212c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b')
export const VK_DELTA_2: bytes = Bytes.fromHex('000c6d2d74ec65cb34fb1e0d0aa456b445fc7cf8c0256f241d89ed3862d5888921cf34232e593ce0fdd4b3cf75e0d879d0bd562fa534cca63bc051e4834086ee1d643fed36fae1b117e3db8a08b3533bf4440df8f552d014054fa7b2da0fea430acc8c0abb00aa72d524bda026920712844eb9b2abfa7d0b7dc7fdbf0d816d45')

// IC[0] is the "free" term; IC[i+1] is multiplied by publicInputs[i].
export const VK_IC_0: bytes = Bytes.fromHex('0a8e8514e23dbb7bca43e7f14fb73e39068fcf7db40c74e4fc833e7362bfcdb0123e9540f25a97c50d415b046a77bd1f177af63dff80a26747a89e09161038ad')
export const VK_IC_1: bytes = Bytes.fromHex('0226f83bce9bf2af5adf1a1f8ecb8add0a8dcfe00321d153b9146b8143ad12370a3d0fe444c80fcea3d74ac1935b5b491c1de635b84dbc0a47382a85c38861bd')
export const VK_IC_2: bytes = Bytes.fromHex('27812447ba51b837eafbc74e963d8750d030a7745ef41d0044f139e27d74262e2d88a4d267cd51fd6cde01c1b4c27796e6e5fe0ba87b8f0aa9bcc671ce8a392d')
export const VK_IC_3: bytes = Bytes.fromHex('0ce6e5684bb97ffcda8f8d88e055d661ce4879f20da891de1972bbb73f5344fb11c36f962b4f24c31fe43c7623e16a5cfb3e5f78d798f1f8efdf560a9b2fbbfb')
export const VK_IC_4: bytes = Bytes.fromHex('091a9dd0909e366efdcdc90daf977904e506772f2684e17dbbdcb6795f33903b2942806720dc56b7548f09501fec09d60c3d5a8717303e947de97bda7984d3c5')

export const VK_IC_LEN: uint64 = 5
export const VK_NPUBLIC: uint64 = 4
