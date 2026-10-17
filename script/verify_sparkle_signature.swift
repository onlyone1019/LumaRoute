import CryptoKit
import Foundation

// Accept only public material on argv. The private key is never passed here.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded:CommandLine.arguments[2]),
      let signature = Data(base64Encoded:CommandLine.arguments[3]) else { exit(2) }
let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:key)
guard publicKey.isValidSignature(signature,for:data) else {
    fputs("Sparkle signature does not match the public key embedded in the app\n",stderr)
    exit(1)
}
