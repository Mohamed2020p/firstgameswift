import UIKit
import SceneKit
import SwiftUI

// MARK: - The single full-screen view controller: SCNView (3D world) with the SwiftUI UI (RootView) hosted on top of it.
// No game logic lives here; GameContext owns everything.

@MainActor
final class GameViewController: UIViewController {

    private var sceneView: SCNView?
    private var hostingController: UIHostingController<RootView>?
    private var gameContext: GameContext?
    private var bootTask: Task<Void, Never>?
    private var didStartBoot: Bool = false

    // MARK: View controller configuration

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return UIRectEdge.all
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.landscape
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return UIInterfaceOrientation.landscapeRight
    }

    override var shouldAutorotate: Bool {
        return true
    }

    // MARK: Life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        view.isMultipleTouchEnabled = true

        let scn: SCNView = SCNView(frame: view.bounds)
        scn.translatesAutoresizingMaskIntoConstraints = false
        scn.backgroundColor = UIColor.black
        scn.preferredFramesPerSecond = 60
        scn.antialiasingMode = SCNAntialiasingMode.multisampling4X
        scn.isJitteringEnabled = false
        scn.rendersContinuously = true
        scn.allowsCameraControl = false
        scn.isMultipleTouchEnabled = true
        view.addSubview(scn)
        pin(scn, to: view)
        sceneView = scn

        let ctx: GameContext = GameContext(view: scn)
        gameContext = ctx
        AppDelegate.activeContext = ctx

        let host: UIHostingController<RootView> = UIHostingController(rootView: RootView(ctx: ctx))
        host.view.backgroundColor = UIColor.clear
        host.view.isOpaque = false
        host.view.isMultipleTouchEnabled = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        pin(host.view, to: view)
        host.didMove(toParent: self)
        hostingController = host
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startBootIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the hosting view above the 3D view even if something re-orders the subviews.
        if let hostView = hostingController?.view {
            view.bringSubviewToFront(hostView)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        gameContext?.save.saveNow()
    }

    // MARK: Helpers

    private func startBootIfNeeded() {
        if didStartBoot { return }
        didStartBoot = true
        guard let ctx = gameContext else { return }
        bootTask = Task { @MainActor in
            await ctx.boot()
        }
    }

    private func pin(_ child: UIView, to parent: UIView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
}
