import Flutter
import UIKit
import UserNotifications
import Contacts

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var contactsChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerContactsChannel(with: engineBridge.pluginRegistry)
  }

  // Show notifications as banners + play sound even when app is in foreground.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  private func registerContactsChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "HangContactsBridge") else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "hang/contacts",
      binaryMessenger: registrar.messenger()
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "UNAVAILABLE", message: "AppDelegate unavailable", details: nil))
        return
      }

      switch call.method {
      case "getContacts", "getPhonebookContacts":
        self.getPhonebookContacts(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    contactsChannel = channel
  }

  private func getPhonebookContacts(result: @escaping FlutterResult) {
    let store = CNContactStore()
    let status = CNContactStore.authorizationStatus(for: .contacts)

    switch status {
    case .authorized:
      self.fetchContacts(store: store, result: result)
    case .notDetermined:
      store.requestAccess(for: .contacts) { granted, error in
        if let error = error {
          result(FlutterError(code: "CONTACTS_ACCESS_ERROR", message: error.localizedDescription, details: nil))
          return
        }
        if granted {
          self.fetchContacts(store: store, result: result)
        } else {
          result(FlutterError(code: "CONTACTS_DENIED", message: "Contacts access denied", details: nil))
        }
      }
    case .denied, .restricted:
      result(FlutterError(code: "CONTACTS_DENIED", message: "Contacts access denied", details: nil))
    @unknown default:
      result(FlutterError(code: "CONTACTS_UNKNOWN", message: "Unknown contacts authorization status", details: nil))
    }
  }

  private func fetchContacts(store: CNContactStore, result: @escaping FlutterResult) {
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor
    ]

    let request = CNContactFetchRequest(keysToFetch: keys)
    var rows: [[String: Any]] = []

    do {
      try store.enumerateContacts(with: request) { contact, _ in
        var phones: [String] = []
        for number in contact.phoneNumbers {
          let value = number.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
          if !value.isEmpty {
            phones.append(value)
          }
        }

        if phones.isEmpty {
          return
        }

        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines)
        let name = fullName.isEmpty ? "Unknown" : fullName
        rows.append([
          "name": name,
          "phones": phones
        ])
      }

      result(rows)
    } catch {
      result(FlutterError(code: "CONTACTS_FETCH_FAILED", message: error.localizedDescription, details: nil))
    }
  }
}
