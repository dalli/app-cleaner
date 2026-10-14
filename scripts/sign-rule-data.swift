// 규칙 데이터 서명 도구 (plan.md 4.6)
//
// 사용법:
//   swift scripts/sign-rule-data.swift keygen <private-key-file>
//       Ed25519 키쌍 생성. 개인키(base64)를 파일에 0600으로 저장하고 공개키(base64)를 출력한다.
//       공개키는 Sources/CleanerCore/RuleUpdate/RuleDataVerifier.swift의 embeddedPublicKeyBase64에 넣는다.
//       개인키는 저장소에 커밋하지 않는다.
//   swift scripts/sign-rule-data.swift pubkey <private-key-file>
//       개인키에 대응하는 공개키(base64) 출력
//   swift scripts/sign-rule-data.swift sign <rule-data-dir> <private-key-file> [version]
//       <rule-data-dir>의 *.json(manifest.json 제외)의 SHA-256으로 manifest.json을 쓰고,
//       manifest.json 바이트 그대로에 대한 Ed25519 서명을 manifest.sig(base64)로 쓴다.
//       version을 생략하면 기존 manifest.json의 version을 유지한다.
//   swift scripts/sign-rule-data.swift verify <rule-data-dir> <public-key-base64>
//       서명과 파일 해시를 확인한다.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readPrivateKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("개인키를 읽을 수 없음: \(path)") }
    return key
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("사용법: sign-rule-data.swift keygen|pubkey|sign|verify …") }

switch command {
case "keygen":
    guard args.count == 2 else { fail("사용법: keygen <private-key-file>") }
    let key = Curve25519.Signing.PrivateKey()
    let path = args[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("이미 있음: \(path)") }
    FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "pubkey":
    guard args.count == 2 else { fail("사용법: pubkey <private-key-file>") }
    print(readPrivateKey(args[1]).publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count == 3 || args.count == 4 else { fail("사용법: sign <rule-data-dir> <private-key-file> [version]") }
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    let key = readPrivateKey(args[2])
    let manifestURL = dir.appendingPathComponent("manifest.json")
    var version = args.count == 4 ? args[3] : nil
    if version == nil, let data = try? Data(contentsOf: manifestURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        version = obj["version"] as? String
    }
    guard let version else { fail("version이 필요함") }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".json") && $0 != "manifest.json" && !$0.hasPrefix(".") }.sorted()
    var files: [String: String] = [:]
    for name in names {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { fail("읽을 수 없음: \(name)") }
        files[name] = sha256Hex(data)
    }
    let formatter = ISO8601DateFormatter()
    let manifest: [String: Any] = ["version": version, "updatedAt": formatter.string(from: Date()), "files": files]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: manifestURL)
    let signature = try key.signature(for: manifestData)
    try Data(signature.base64EncodedString().utf8).write(to: dir.appendingPathComponent("manifest.sig"))
    print("서명함: version \(version), 파일 \(names.count)개")

case "verify":
    guard args.count == 3 else { fail("사용법: verify <rule-data-dir> <public-key-base64>") }
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    guard let raw = Data(base64Encoded: args[2]), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("공개키 형식 오류")
    }
    guard let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
          let sigText = try? String(contentsOf: dir.appendingPathComponent("manifest.sig"), encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("manifest 없음") }
    guard pub.isValidSignature(sig, for: manifestData) else { fail("서명 불일치") }
    guard let obj = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          let files = obj["files"] as? [String: String] else { fail("manifest 형식 오류") }
    for (name, hash) in files.sorted(by: { $0.key < $1.key }) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)), sha256Hex(data) == hash else {
            fail("해시 불일치: \(name)")
        }
    }
    print("확인됨: version \(obj["version"] ?? "?"), 파일 \(files.count)개")

default:
    fail("알 수 없는 명령: \(command)")
}
