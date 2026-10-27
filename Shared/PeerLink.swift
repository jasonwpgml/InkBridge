import Foundation
import MultipeerConnectivity
import Combine

final class PeerLink: NSObject, ObservableObject {
    static let service = "inkbridge-v1"
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var connectedName: String?
    @Published var status = "연결 대기"
    @Published private(set) var code = PeerLink.newCode()
    var received: ((MessageKind, Data) -> Void)?
    var connectionChanged: ((Bool) -> Void)?
    private let peer: MCPeerID
    private let host: Bool
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var updates = LatestUpdates()
    private var chosenPeer: MCPeerID?
    private var receivedSequences: [MessageKind: UInt64] = [:]
    private var invitationPending = false
    private var wrongCodes = 0

    private static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999999)) }

    init(host: Bool, name: String) {
        self.host = host
        peer = MCPeerID(displayName: String(name.prefix(60)))
        super.init()
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    func start() {
        if host {
            guard advertiser == nil else { return }
            let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["version": "1"], serviceType: Self.service)
            advertiser.delegate = self; advertiser.startAdvertisingPeer(); self.advertiser = advertiser
        } else {
            guard browser == nil else { return }
            let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
            browser.delegate = self; browser.startBrowsingForPeers(); self.browser = browser
        }
    }

    func suspend() {
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        nearby = []
        disconnect()
    }

    func connect(to peer: MCPeerID, code: String) {
        guard connectedName == nil, !invitationPending, code.count == 6,
              code.allSatisfy(\.isNumber) else { return }
        chosenPeer = peer; invitationPending = true
        status = "\(peer.displayName)에 연결 중…"
        browser?.invitePeer(peer, to: session, withContext: Data(code.utf8), timeout: 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            guard let self, self.invitationPending, self.connectedName == nil else { return }
            self.session.disconnect(); self.chosenPeer = nil; self.invitationPending = false
            self.status = "연결되지 않았습니다. 맥의 코드와 네트워크를 확인하세요."
        }
    }

    func disconnect() {
        session.disconnect()
        clearConnection()
    }

    private func clearConnection() {
        connectedName = nil; chosenPeer = nil; invitationPending = false
        updates = LatestUpdates(); receivedSequences = [:]
        status = "연결 대기"
        connectionChanged?(false)
    }

    /// Returns false when a latest update is left queued, where a newer update may still replace it.
    @discardableResult
    func send(_ kind: MessageKind, body: Data = Data(), latest: Bool = false) -> Bool {
        guard connectedName != nil, body.count + 10 <= WireMessage.maximumBytes else { return false }
        if latest {
            guard let message = updates.submit(body, kind: kind) else { return false }
            transmit(message)
        } else { transmit(WireMessage(kind: kind, body: body)) }
        return true
    }

    private func transmit(_ message: WireMessage) {
        guard let chosenPeer, session.connectedPeers.contains(chosenPeer) else { return }
        do { try session.send(message.encoded(), toPeers: [chosenPeer], with: .reliable) }
        catch { disconnect(); status = "전송 실패: \(error.localizedDescription)" }
    }
}

extension PeerLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, peerID == self.chosenPeer else { return }
            switch state {
            case .connected:
                self.invitationPending = false
                self.connectedName = peerID.displayName
                self.status = "\(peerID.displayName) 연결됨"
                self.connectionChanged?(true)
            case .notConnected: self.clearConnection()
            case .connecting: self.status = "연결 중…"
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = WireMessage(data: data) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectedName != nil, peerID == self.chosenPeer else { return }
            if message.kind == .acknowledgement {
                if message.body.count == 1, let kind = message.body.first.flatMap(MessageKind.init(rawValue:)),
                   let next = self.updates.acknowledge(message.sequence, kind: kind) { self.transmit(next) }
                return
            }
            if message.sequence == 0 || message.sequence > (self.receivedSequences[message.kind] ?? 0) {
                self.receivedSequences[message.kind] = message.sequence
                self.received?(message.kind, message.body)
            }
            if message.sequence != 0 {
                self.transmit(WireMessage(kind: .acknowledgement, sequence: message.sequence, body: Data([message.kind.rawValue])))
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { invitationHandler(false, nil); return }
            let rightCode = context == Data(self.code.utf8)
            let accept = self.connectedName == nil && self.chosenPeer == nil && rightCode
            if accept { self.chosenPeer = peerID; self.wrongCodes = 0 }
            if !rightCode {
                // Three misses replace the code, so nearby devices cannot work through all million codes.
                self.wrongCodes += 1
                if self.wrongCodes >= 3 {
                    self.wrongCodes = 0
                    self.code = Self.newCode()
                    self.status = "틀린 코드가 여러 번 들어와 연결 코드를 바꿨습니다."
                }
            }
            invitationHandler(accept, accept ? self.session : nil)
        }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.status = "기기 검색을 시작할 수 없습니다: \(error.localizedDescription)" }
    }
}

extension PeerLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if info?["version"] == "1", !self.nearby.contains(peerID) { self.nearby.append(peerID) }
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.nearby.removeAll { $0 == peerID } }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.status = "맥 검색 실패: \(error.localizedDescription)" }
    }
}
