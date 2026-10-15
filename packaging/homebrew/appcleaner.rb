# dallisoft/homebrew-tap 의 Formula/appcleaner.rb 원본 (tap 쪽을 직접 고치지 말 것).
# 릴리즈(v* 태그)마다 .github/workflows/release.yml 이 이 파일을 tap에 복사하고
# scripts/update-homebrew-formula.sh 로 url·sha256을 그 태그의 소스 tarball로 고쳐 푸시한다.
class Appcleaner < Formula
  desc "Find and safely remove leftover files of macOS apps"
  homepage "https://github.com/dallisoft/app-cleaner"
  url "https://github.com/dallisoft/app-cleaner/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "0f00af9ed6fdc329e9babe00edc4427618b09e5595245c4c587aef8a7905fd95"
  head "https://github.com/dallisoft/app-cleaner.git", branch: "main"

  # Package.swift: swift-tools-version 6.0, platforms .macOS(.v14).
  # Swift 6 툴체인(Command Line Tools 16 이상 또는 Xcode 16 이상)으로 빌드한다 — Xcode.app은 필요 없다.
  depends_on macos: :sonoma

  def install
    # Homebrew 빌드 샌드박스 안에서는 SwiftPM의 sandbox-exec를 중첩할 수 없다
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "appcleaner"
    bin_path = Utils.safe_popen_read("swift", "build", "-c", "release", "--show-bin-path").chomp
    # CLI는 실행 파일 옆의 리소스 번들(규칙 데이터·관리자 스크립트·번역)을 쓴다.
    # bin의 심볼릭 링크로 실행해도 링크를 해석해 libexec의 번들을 찾는다 (BundledResources).
    libexec.install "#{bin_path}/appcleaner", "#{bin_path}/AppCleaner_CleanerCore.bundle"
    bin.install_symlink libexec/"appcleaner"
  end

  test do
    output = shell_output("#{bin}/appcleaner version --lang en")
    assert_match "appcleaner #{version}", output
    # 리소스 번들을 못 찾으면 규칙 데이터 버전이 unknown으로 나온다
    refute_match "unknown", output
  end
end
