// iOS document bridge added 2026-10-18. GPL-3.0-or-later.
import Flutter
import UIKit
import UniformTypeIdentifiers
import CryptoKit

final class IOSDocumentsPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = IOSDocumentsPlugin()
    registrar.addMethodCallDelegate(instance, channel: FlutterMethodChannel(
      name: "org.mewx.wenku8/book_documents", binaryMessenger: registrar.messenger()))
  }

  private let io = DispatchQueue(label: "wenku8.documents")
  private var pending: FlutterResult?
  private var operation = ""
  private let manager = FileManager.default
  private let syncKey = "wenku8.ios.sync.bookmark"
  private var staging: URL {
    manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ios-book-imports", isDirectory: true)
  }
  private var syncFolder: URL {
    manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ios-book-sync", isDirectory: true)
  }

  private enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? {
      switch self { case .message(let text): return text }
    }
  }

  private func perform(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any?) {
    io.async {
      do {
        let value = try work()
        DispatchQueue.main.async { result(value) }
      } catch {
        let message = (error as? Failure)?.errorDescription ?? "文件操作失败，请在“文件”中确认文档已下载后重试"
        DispatchQueue.main.async { result(FlutterError(code: "DOCUMENT", message: message, details: nil)) }
      }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pickBook", "pickBooks", "pickFont", "openSync", "createSync":
      present(call.method, result: result)
    case "scanFolderInfo": result(nil)
    case "scanFormats": result(["txt", "epub"])
    case "setScanAutomatic", "setScanFormats", "disconnectScanFolder", "finishBookScan": result(nil)
    case "selectAllScan", "selectScanFolder", "scanBooks", "stageScanBook":
      result(FlutterError(code: "IOS_FILES", message: "请使用“导入 TXT / EPUB”在系统“文件”中多选书籍", details: nil))
    case "releaseBooks":
      perform(result) {
        for path in args["paths"] as? [String] ?? [] {
          let url = try self.sandboxFile(path)
          if url.path.hasPrefix(self.staging.resolvingSymlinksInPath().path + "/") {
            try? self.manager.removeItem(at: url)
          }
        }
        return nil
      }
    case "prepareBook":
      let name = args["name"] as? String ?? ""
      result([["name": name, "error": "iOS 当前支持 TXT 和 EPUB，请先转换格式后导入"]])
    case "decodeText", "decodeTextFile":
      perform(result) {
        let url = try self.sandboxFile(args["path"] as? String ?? "")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 128 * 1024 * 1024 else {
          throw Failure.message("TXT 文件为空或超过 128 MiB")
        }
        let text = try self.decode(Data(contentsOf: url), encoding: args["encoding"] as? String ?? "auto")
        if call.method == "decodeText" { return text }
        try self.manager.createDirectory(at: self.staging, withIntermediateDirectories: true)
        let output = self.staging.appendingPathComponent(UUID().uuidString + ".txt")
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output.path
      }
    case "syncInfo":
      perform(result) { try self.syncInfo() }
    case "disconnectSync":
      perform(result) {
        UserDefaults.standard.removeObject(forKey: self.syncKey)
        UserDefaults.standard.removeObject(forKey: self.syncKey + ".created")
        return nil
      }
    case "readSync":
      perform(result) {
        let url = try self.syncURL()
        try self.manager.createDirectory(at: self.syncFolder, withIntermediateDirectories: true)
        let before = self.syncFolder.appendingPathComponent("before.wenku8")
        let output = self.syncFolder.appendingPathComponent("next.wenku8")
        try self.withDocument(url, writing: false) { actual in
          let size = try actual.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 600 * 1024 * 1024 else { throw Failure.message("同步文件超过 600 MiB") }
          let bytes = try Data(contentsOf: actual)
          try bytes.write(to: before, options: .atomic)
        }
        return ["path": before.path, "outputPath": output.path]
      }
    case "writeSync":
      perform(result) {
        let expected = try self.sandboxFile(args["expectedPath"] as? String ?? "")
        let next = try self.sandboxFile(args["path"] as? String ?? "")
        guard expected.path == self.syncFolder.appendingPathComponent("before.wenku8").resolvingSymlinksInPath().path,
              next.path == self.syncFolder.appendingPathComponent("next.wenku8").resolvingSymlinksInPath().path else {
          throw Failure.message("同步文件位置无效，请重新读取云文档")
        }
        let oldData = try Data(contentsOf: expected)
        let newData = try Data(contentsOf: next)
        guard newData.count <= 600 * 1024 * 1024 else { throw Failure.message("同步文件过大") }
        let url = try self.syncURL()
        try self.withDocument(url, writing: true) { actual in
          let current = try Data(contentsOf: actual)
          guard SHA256.hash(data: current) == SHA256.hash(data: oldData) else {
            throw Failure.message("云文档已在其他设备更新，请重新同步后重试")
          }
          try current.write(to: self.syncFolder.appendingPathComponent("previous.wenku8"), options: .atomic)
          try newData.write(to: actual, options: .atomic)
          guard try Data(contentsOf: actual) == newData else { throw Failure.message("云文档写入校验失败，本机副本已保留") }
        }
        UserDefaults.standard.set(false, forKey: self.syncKey + ".created")
        return nil
      }
    case "recoverSync":
      perform(result) {
        let which = args["which"] as? String ?? ""
        let name = which == "previous" ? "previous.wenku8" : "next.wenku8"
        let url = self.syncFolder.appendingPathComponent(name)
        return self.manager.fileExists(atPath: url.path) ? url.path : nil
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func sandboxFile(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    guard url.path.hasPrefix(home + "/") else { throw Failure.message("文件不在本应用的存储空间内") }
    return url
  }

  private func decode(_ bytes: Data, encoding: String) throws -> String {
    let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let encodings: [String.Encoding]
    switch encoding {
    case "UTF-8": encodings = [.utf8]
    case "GB18030": encodings = [gb]
    case "UTF-16LE": encodings = [.utf16LittleEndian]
    case "UTF-16BE": encodings = [.utf16BigEndian]
    case "auto":
      if bytes.starts(with: [0xff, 0xfe]) { encodings = [.utf16LittleEndian] }
      else if bytes.starts(with: [0xfe, 0xff]) { encodings = [.utf16BigEndian] }
      else { encodings = [.utf8, gb] }
    default: throw Failure.message("不支持的文本编码")
    }
    for encoding in encodings {
      if let value = String(data: bytes, encoding: encoding) {
        return value.hasPrefix("\u{feff}") ? String(value.dropFirst()) : value
      }
    }
    throw Failure.message("无法识别文本编码，请在本地书库设置中选择正确的编码")
  }

  private func controller() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    var controller = windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  private func present(_ method: String, result: @escaping FlutterResult) {
    guard pending == nil else { result(FlutterError(code: "BUSY", message: "请先完成当前文档选择", details: nil)); return }
    guard let controller = controller() else { result(FlutterError(code: "PICKER", message: "系统文件窗口无法打开", details: nil)); return }
    let picker: UIDocumentPickerViewController
    if method == "createSync" {
      let file = manager.temporaryDirectory.appendingPathComponent("wenku8-library.wenku8")
      do { try Data().write(to: file) }
      catch { result(FlutterError(code: "DOCUMENT", message: "无法创建同步文件", details: nil)); return }
      picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
    } else {
      let types: [UTType]
      if method == "pickFont" {
        types = [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf")].compactMap { $0 }
      } else if method == "openSync" { types = [.data] }
      else { types = [.plainText, UTType(filenameExtension: "epub") ?? .data] }
      picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: method != "openSync")
      picker.allowsMultipleSelection = method == "pickBooks"
    }
    operation = method
    pending = result
    picker.delegate = self
    controller.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let callback = pending
    let multiple = operation == "pickBooks"
    pending = nil
    operation = ""
    callback?(multiple ? [] : nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pending else { return }
    let method = operation
    pending = nil
    operation = ""
    if method == "openSync" || method == "createSync" {
      guard let url = urls.first else { result(nil); return }
      perform(result) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: self.syncKey)
        UserDefaults.standard.set(method == "createSync", forKey: self.syncKey + ".created")
        return try self.syncInfo()
      }
      return
    }
    perform(result) {
      try self.manager.createDirectory(at: self.staging, withIntermediateDirectories: true)
      var values: [[String: String]] = []
      for url in urls.prefix(200) {
        let name = url.lastPathComponent
        do {
          let ext = url.pathExtension.lowercased()
          let allowed = method == "pickFont" ? ["ttf", "otf"] : ["txt", "epub"]
          guard allowed.contains(ext) else { throw Failure.message("请选择 TXT / EPUB 书籍，或 TTF / OTF 字体") }
          let limit = method == "pickFont" ? 32 * 1024 * 1024 : (ext == "txt" ? 128 : 512) * 1024 * 1024
          let destination = self.staging.appendingPathComponent(UUID().uuidString + "." + ext)
          try self.withDocument(url, writing: false) { actual in
            let size = try actual.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= limit else { throw Failure.message("文件为空或超过大小限制") }
            try self.manager.copyItem(at: actual, to: destination)
          }
          values.append(["name": name, "path": destination.path])
        } catch {
          values.append(["name": name, "error": (error as? Failure)?.errorDescription ?? "文件读取失败"])
        }
      }
      if method == "pickBooks" { return values }
      guard let first = values.first else { return nil }
      if let error = first["error"] { throw Failure.message(error) }
      return first
    }
  }

  private func syncURL() throws -> URL {
    guard let data = UserDefaults.standard.data(forKey: syncKey) else { throw Failure.message("请先连接一个同步文件") }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    if stale {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let next = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(next, forKey: syncKey)
    }
    return url
  }

  private func syncInfo() throws -> [String: Any]? {
    guard UserDefaults.standard.data(forKey: syncKey) != nil else { return nil }
    let url = try syncURL()
    return ["name": url.lastPathComponent, "provider": "iOS 文件 / iCloud Drive", "authority": "ios.files",
            "created": UserDefaults.standard.bool(forKey: syncKey + ".created")]
  }

  private func withDocument(_ url: URL, writing: Bool, _ work: @escaping (URL) throws -> Void) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var operationError: Error?
    let action: (URL) -> Void = { actual in
      do { try work(actual) } catch { operationError = error }
    }
    if writing {
      coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: action)
    } else {
      coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: action)
    }
    if let error = operationError { throw error }
    if let error = coordinationError { throw error }
  }
}
