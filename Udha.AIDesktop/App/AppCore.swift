import Foundation
import Observation

@MainActor
@Observable
final class AppCore {
    let config: ConfigStore
    let keychain: KeychainStore
    let stateStore: SessionStateStore
    let sessionManager: SessionManager
    let notifications: NotificationBus
    let proactive: ProactiveVoiceEngine
    let contextFeed: ContextFeed
    let tools: ToolHandlers
    let scheduler: ActionScheduler
    let activity: ActivityLog
    let conversational: ConversationalAgent
    let voice: VoiceController
    let classifier: HaikuClassifier
    let openRouter: OpenRouterClient
    let slack: SlackManager

    init() {
        let keychain = KeychainStore(service: "solutions.amk.Udha-AIDesktop")
        let config = ConfigStore()
        self.keychain = keychain
        self.config = config

        let stateStore = SessionStateStore()
        self.stateStore = stateStore

        let openRouter = OpenRouterClient(keychain: keychain)
        self.openRouter = openRouter

        let classifier = HaikuClassifier(openRouter: openRouter, config: config)
        self.classifier = classifier

        let activity = ActivityLog()
        self.activity = activity

        let notifications = NotificationBus(stateStore: stateStore, config: config)
        self.notifications = notifications

        let elevenLabs = ElevenLabsTTSClient(keychain: keychain, config: config)
        let proactive = ProactiveVoiceEngine(
            stateStore: stateStore,
            notifications: notifications,
            tts: elevenLabs,
            config: config
        )
        self.proactive = proactive

        let sessionManager = SessionManager(
            stateStore: stateStore,
            classifier: classifier,
            config: config,
            activity: activity
        )
        self.sessionManager = sessionManager

        let contextFeed = ContextFeed(stateStore: stateStore, notifications: notifications)
        self.contextFeed = contextFeed

        let scheduler = ActionScheduler(activity: activity)
        self.scheduler = scheduler

        let tools = ToolHandlers(
            stateStore: stateStore,
            sessionManager: sessionManager,
            notifications: notifications,
            scheduler: scheduler,
            activity: activity,
            config: config
        )
        self.tools = tools

        let conversational = ConversationalAgent(
            keychain: keychain,
            config: config,
            contextFeed: contextFeed,
            tools: tools,
            proactive: proactive,
            activity: activity
        )
        self.conversational = conversational

        let voice = VoiceController(agent: conversational, proactive: proactive)
        self.voice = voice

        let slack = SlackManager(
            config: config,
            keychain: keychain,
            proactive: proactive,
            openRouter: openRouter
        )
        self.slack = slack

        scheduler.tools = tools
        tools.slack = slack
        contextFeed.sessionManager = sessionManager

        config.load()
        BootstrapCredentials.seed(keychain: keychain, config: config)
    }

    func start() {
        AudioPlayer.shared.start()
        applyOutputDevice()
        // proactive engine lifecycle is owned by VoiceController so the mic
        // toggle doubles as a global speech mute.
        sessionManager.restoreSessions()
        slack.start()
    }

    func applyOutputDevice() {
        let uid = config.config.voice.outputDeviceUID
        AudioPlayer.shared.preferredOutputDeviceUID = uid.isEmpty ? nil : uid
    }

    func shutdown() {
        slack.stop()
        sessionManager.shutdownAll()
        voice.turnOff()
        config.save()
    }
}
