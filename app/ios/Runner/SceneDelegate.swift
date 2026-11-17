import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // Links that reach the running app (famio://open from ntfy, famio://share
  // from the share extension, calendar files from "Öffnen mit") also go
  // straight to OpenedFiles: Flutter's forwarding to the scene callbacks of
  // plugins did not deliver them (#385, #567). OpenedFiles takes each link
  // once and ignores everything else.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    _ = OpenedFiles.shared.scene(scene, openURLContexts: URLContexts)
  }
}
