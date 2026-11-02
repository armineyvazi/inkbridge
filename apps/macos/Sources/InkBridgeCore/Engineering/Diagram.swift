import CoreGraphics
import Foundation

/// Engineering diagrams: structured objects on the canvas, separate from ink.
///
/// Nodes are components (services, databases, queues, flowchart steps…).
/// Connectors are first-class: they reference their source and target nodes
/// by ID, and their path is *computed* from the nodes' frames, so moving a
/// node re-routes every connector attached to it. Coordinates are canvas px.
public struct Diagram: Codable, Equatable, Sendable {
  public var nodes: [DiagramNode] = []
  public var edges: [DiagramEdge] = []

  public init(nodes: [DiagramNode] = [], edges: [DiagramEdge] = []) {
    self.nodes = nodes
    self.edges = edges
  }

  public var isEmpty: Bool { nodes.isEmpty && edges.isEmpty }

  public func node(_ id: String) -> DiagramNode? { nodes.first { $0.id == id } }

  /// Removes nodes and every connector touching them.
  public mutating func remove(_ ids: Set<String>) {
    nodes.removeAll { ids.contains($0.id) }
    edges.removeAll { ids.contains($0.id) || ids.contains($0.from) || ids.contains($0.to) }
  }

  /// Connector paths in canvas px, computed from the current node frames.
  ///
  /// When several connectors use the same side of a node they get separate
  /// "ports", spread along that side in the order of their other ends, so
  /// they never start from one point and overlap.
  public func path(of edge: DiagramEdge) -> [CGPoint] {
    guard let a = node(edge.from), let b = node(edge.to), a.id != b.id else { return [] }
    let (sa, sb, horizontal) = ConnectorRouter.sides(from: a.frame, to: b.frame)
    let p1 = port(node: a, side: sa, edge: edge.id)
    let p2 = port(node: b, side: sb, edge: edge.id)
    return ConnectorRouter.route(p1, p2, horizontal: horizontal, style: edge.style)
  }

  /// The anchor of `edge` on `side` of `node`, spread among all connectors on that side.
  private func port(node n: DiagramNode, side: ConnectorRouter.Side, edge id: String) -> CGPoint {
    var users: [(id: String, key: CGFloat)] = []
    for e in edges where e.from == n.id || e.to == n.id {
      guard let other = node(e.from == n.id ? e.to : e.from), other.id != n.id else { continue }
      let s =
        e.from == n.id
        ? ConnectorRouter.sides(from: n.frame, to: other.frame).0
        : ConnectorRouter.sides(from: other.frame, to: n.frame).1
      if s == side { users.append((e.id, side.isVertical ? other.frame.midY : other.frame.midX)) }
    }
    users.sort { $0.key == $1.key ? $0.id < $1.id : $0.key < $1.key }
    let i = users.firstIndex { $0.id == id } ?? 0
    // Diamonds (decisions) and ellipses only have one sensible point per side: the vertex.
    let single = [.diamond, .cloud].contains(n.component.shape)
    let t = single ? 0.5 : CGFloat(i + 1) / CGFloat(users.count + 1)
    let f = n.frame
    switch side {
    case .left: return CGPoint(x: f.minX, y: f.minY + f.height * t)
    case .right: return CGPoint(x: f.maxX, y: f.minY + f.height * t)
    case .top: return CGPoint(x: f.minX + f.width * t, y: f.minY)
    case .bottom: return CGPoint(x: f.minX + f.width * t, y: f.maxY)
    }
  }

  /// Bounds of everything, for Fit.
  public var bounds: CGRect? {
    nodes.map(\.frame).reduce(nil as CGRect?) { acc, r in acc.map { $0.union(r) } ?? r }
  }
}

public struct DiagramNode: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  /// A `ComponentCatalog` kind, e.g. "postgres", "api_gateway", "decision".
  public var kind: String
  public var label: String
  public var frame: CGRect
  /// Free-form notes shown under the label (e.g. a table's columns, a port).
  public var detail: String = ""

  public init(
    id: String = "n-\(UUID().uuidString.prefix(8))", kind: String, label: String, frame: CGRect,
    detail: String = ""
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.frame = frame
    self.detail = detail
  }

  public var component: Component { ComponentCatalog.component(kind) }
}

public struct DiagramEdge: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case http, grpc, graphql, websocket, async, event, queue, database, dataflow, dependency

    public var title: String {
      switch self {
      case .http: return "HTTP / REST"
      case .grpc: return "gRPC"
      case .graphql: return "GraphQL"
      case .websocket: return "WebSocket"
      case .async: return "Async message"
      case .event: return "Event stream"
      case .queue: return "Queue"
      case .database: return "Database connection"
      case .dataflow: return "Data flow"
      case .dependency: return "Dependency"
      }
    }

    /// Dash pattern in points (empty = solid). Async and event flows are dashed,
    /// dependencies dotted: the usual architecture-diagram conventions.
    public var dash: [CGFloat] {
      switch self {
      case .async, .event, .queue: return [7, 5]
      case .dependency: return [2, 4]
      default: return []
      }
    }

    public var defaultLabel: String {
      switch self {
      case .grpc: return "gRPC"
      case .graphql: return "GraphQL"
      case .websocket: return "WS"
      case .event: return "events"
      case .queue: return "enqueue"
      case .database: return "SQL"
      default: return ""
      }
    }
  }

  public enum Style: String, Codable, CaseIterable, Sendable {
    case straight, orthogonal, curved
  }

  public var id: String
  public var from: String
  public var to: String
  public var kind: Kind
  public var style: Style
  public var label: String

  public init(
    id: String = "e-\(UUID().uuidString.prefix(8))", from: String, to: String, kind: Kind = .http,
    style: Style = .orthogonal, label: String? = nil
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.kind = kind
    self.style = style
    self.label = label ?? kind.defaultLabel
  }
}

// MARK: - Components

public struct Component: Equatable, Sendable, Identifiable {
  public enum Shape: String, Sendable {
    case box, rounded, cylinder, diamond, stadium, parallelogram, note, queue, hexagon, actor, cloud
  }

  public var id: String
  public var title: String
  public var category: String
  /// SF Symbol name for the Mac; the tablet draws the shape plus the title.
  public var symbol: String
  public var shape: Shape
  public var size: CGSize
}

/// The searchable component library.
public enum ComponentCatalog {
  public static let categories = [
    "Application", "Infrastructure", "Data", "Messaging", "Network", "People & systems",
    "Flowchart", "Notes",
  ]

  public static let all: [Component] = {
    func c(
      _ id: String, _ title: String, _ cat: String, _ symbol: String,
      _ shape: Component.Shape = .rounded,
      _ w: CGFloat = 160, _ h: CGFloat = 72
    ) -> Component {
      Component(
        id: id, title: title, category: cat, symbol: symbol, shape: shape,
        size: CGSize(width: w, height: h))
    }
    return [
      c("web_app", "Web App", "Application", "globe"),
      c("mobile_app", "Mobile App", "Application", "iphone"),
      c("backend_service", "Backend Service", "Application", "server.rack"),
      c("microservice", "Microservice", "Application", "shippingbox"),
      c("api_gateway", "API Gateway", "Application", "arrow.triangle.branch"),
      c("reverse_proxy", "Reverse Proxy", "Application", "arrow.left.arrow.right"),
      c("auth_service", "Auth Service", "Application", "lock.shield"),
      c("worker", "Worker", "Application", "gearshape.2"),
      c("scheduler", "Scheduler", "Application", "clock"),
      c("server", "Server", "Infrastructure", "server.rack", .box),
      c("container", "Container", "Infrastructure", "shippingbox.fill", .box),
      c("docker", "Docker Host", "Infrastructure", "cube.box", .box),
      c(
        "k8s_cluster", "Kubernetes Cluster", "Infrastructure", "circle.hexagongrid", .rounded, 260,
        160),
      c("k8s_pod", "K8s Pod", "Infrastructure", "hexagon", .hexagon, 120, 80),
      c("k8s_deployment", "K8s Deployment", "Infrastructure", "square.stack.3d.up"),
      c("load_balancer", "Load Balancer", "Infrastructure", "arrow.triangle.merge"),
      c("cdn", "CDN", "Infrastructure", "globe.americas", .cloud),
      c("firewall", "Firewall", "Infrastructure", "flame", .box),
      c("cloud", "Cloud Provider", "Infrastructure", "cloud", .cloud, 200, 100),
      c("postgres", "PostgreSQL", "Data", "cylinder", .cylinder, 130, 90),
      c("mysql", "MySQL", "Data", "cylinder", .cylinder, 130, 90),
      c("mongodb", "MongoDB", "Data", "leaf", .cylinder, 130, 90),
      c("redis", "Redis Cache", "Data", "bolt", .cylinder, 130, 90),
      c("elasticsearch", "Elasticsearch", "Data", "magnifyingglass", .cylinder, 130, 90),
      c("object_storage", "Object Storage", "Data", "archivebox", .box),
      c("data_warehouse", "Data Warehouse", "Data", "cylinder.split.1x2", .cylinder, 150, 90),
      c("table", "Table", "Data", "tablecells", .box, 200, 120),
      c("message_queue", "Message Queue", "Messaging", "tray.full", .queue, 170, 64),
      c(
        "kafka", "Kafka Topic", "Messaging", "point.3.connected.trianglepath.dotted", .queue, 170,
        64),
      c("rabbitmq", "RabbitMQ", "Messaging", "tray.2", .queue, 170, 64),
      c(
        "event_bus", "Event Bus", "Messaging", "antenna.radiowaves.left.and.right", .queue, 200, 64),
      c("client", "Client", "Network", "laptopcomputer", .box),
      c("router", "Router", "Network", "wifi.router", .box),
      c("gateway", "Gateway", "Network", "network", .box),
      c("dns", "DNS", "Network", "globe.badge.chevron.backward", .box),
      c("user", "User", "People & systems", "person", .actor, 90, 110),
      c("external_system", "External System", "People & systems", "square.dashed", .box),
      c(
        "c4_system", "Software System (C4)", "People & systems", "square.grid.2x2", .rounded, 200,
        110),
      c(
        "c4_container", "Container (C4)", "People & systems", "square.on.square", .rounded, 180, 100
      ),
      c("start_end", "Start / End", "Flowchart", "circle", .stadium, 140, 56),
      c("process", "Process", "Flowchart", "rectangle", .box, 150, 64),
      c("decision", "Decision", "Flowchart", "diamond", .diamond, 150, 100),
      c("io", "Input / Output", "Flowchart", "parallelogram", .parallelogram, 160, 64),
      c("subprocess", "Subprocess", "Flowchart", "rectangle.split.3x1", .box, 160, 64),
      c("note", "Sticky Note", "Notes", "note.text", .note, 160, 120),
      c("callout", "Callout", "Notes", "text.bubble", .note, 180, 90),
    ]
  }()

  public static func component(_ id: String) -> Component {
    all.first { $0.id == id }
      ?? Component(
        id: id, title: id, category: "Other", symbol: "square", shape: .rounded,
        size: CGSize(width: 160, height: 72))
  }

  /// Case-insensitive match on title, id, category.
  public static func search(_ query: String) -> [Component] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return all }
    return all.filter {
      $0.title.lowercased().contains(q) || $0.id.contains(q) || $0.category.lowercased().contains(q)
    }
  }
}

// MARK: - Routing

public enum ConnectorRouter {
  public enum Side {
    case left, right, top, bottom
    var isVertical: Bool { self == .left || self == .right }
  }

  /// The boundary sides facing each other: left/right when the nodes are
  /// more side by side, top/bottom when more stacked.
  public static func sides(from a: CGRect, to b: CGRect) -> (Side, Side, horizontal: Bool) {
    let dx = b.midX - a.midX
    let dy = b.midY - a.midY
    if abs(dx) >= abs(dy) { return dx >= 0 ? (.right, .left, true) : (.left, .right, true) }
    return dy >= 0 ? (.bottom, .top, false) : (.top, .bottom, false)
  }

  /// Single connector between two frames, attached at the side midpoints.
  public static func route(from a: CGRect, to b: CGRect, style: DiagramEdge.Style) -> [CGPoint] {
    let (sa, sb, horizontal) = sides(from: a, to: b)
    func mid(_ r: CGRect, _ s: Side) -> CGPoint {
      switch s {
      case .left: return CGPoint(x: r.minX, y: r.midY)
      case .right: return CGPoint(x: r.maxX, y: r.midY)
      case .top: return CGPoint(x: r.midX, y: r.minY)
      case .bottom: return CGPoint(x: r.midX, y: r.maxY)
      }
    }
    return route(mid(a, sa), mid(b, sb), horizontal: horizontal, style: style)
  }

  public static func route(_ p1: CGPoint, _ p2: CGPoint, horizontal: Bool, style: DiagramEdge.Style)
    -> [CGPoint]
  {
    let dx = p2.x - p1.x
    let dy = p2.y - p1.y
    switch style {
    case .straight:
      return [p1, p2]
    case .orthogonal:
      if horizontal {
        if abs(p1.y - p2.y) < 0.5 { return [p1, p2] }
        let mx = (p1.x + p2.x) / 2
        return [p1, CGPoint(x: mx, y: p1.y), CGPoint(x: mx, y: p2.y), p2]
      }
      if abs(p1.x - p2.x) < 0.5 { return [p1, p2] }
      let my = (p1.y + p2.y) / 2
      return [p1, CGPoint(x: p1.x, y: my), CGPoint(x: p2.x, y: my), p2]
    case .curved:
      // Cubic Bézier leaving and entering perpendicular to the sides, sampled
      // so every renderer (Mac, tablet, SVG, PDF) draws the same polyline.
      let k = horizontal ? abs(p2.x - p1.x) / 2 : abs(p2.y - p1.y) / 2
      let c1 =
        horizontal
        ? CGPoint(x: p1.x + (dx >= 0 ? k : -k), y: p1.y)
        : CGPoint(x: p1.x, y: p1.y + (dy >= 0 ? k : -k))
      let c2 =
        horizontal
        ? CGPoint(x: p2.x - (dx >= 0 ? k : -k), y: p2.y)
        : CGPoint(x: p2.x, y: p2.y - (dy >= 0 ? k : -k))
      return (0...16).map { i -> CGPoint in
        let t = CGFloat(i) / 16
        let u = 1 - t
        let uu = u * u
        let tt = t * t
        let x = uu * u * p1.x + 3 * uu * t * c1.x + 3 * u * tt * c2.x + tt * t * p2.x
        let y = uu * u * p1.y + 3 * uu * t * c1.y + 3 * u * tt * c2.y + tt * t * p2.y
        return CGPoint(x: x, y: y)
      }
    }
  }

  /// Point at the middle of a polyline (by length), for the label.
  public static func midpoint(_ pts: [CGPoint]) -> CGPoint {
    guard pts.count > 1 else { return pts.first ?? .zero }
    let segs = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
    var half = segs.reduce(0, +) / 2
    for (i, len) in segs.enumerated() {
      if half <= len, len > 0 {
        let t = half / len
        return CGPoint(
          x: pts[i].x + (pts[i + 1].x - pts[i].x) * t, y: pts[i].y + (pts[i + 1].y - pts[i].y) * t)
      }
      half -= len
    }
    return pts.last!
  }

  public static func distance(_ p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
    zip(pts, pts.dropFirst()).map { a, b -> CGFloat in
      let abx = b.x - a.x
      let aby = b.y - a.y
      let len2 = abx * abx + aby * aby
      let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
      return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }.min() ?? .infinity
  }
}

// MARK: - Editing helpers

public enum DiagramEditing {
  /// Topmost node at a canvas point.
  public static func hitNode(_ d: Diagram, at p: CGPoint) -> DiagramNode? {
    d.nodes.last { $0.frame.insetBy(dx: -2, dy: -2).contains(p) }
  }

  public static func hitEdge(_ d: Diagram, at p: CGPoint, tolerance: CGFloat) -> DiagramEdge? {
    d.edges.last { ConnectorRouter.distance(p, toPolyline: d.path(of: $0)) <= tolerance }
  }

  public static func snap(_ v: CGFloat, grid: CGFloat) -> CGFloat {
    grid > 0 ? (v / grid).rounded() * grid : v
  }

  public enum Alignment: String, CaseIterable, Sendable {
    case left, centerX, right, top, centerY, bottom, distributeH, distributeV
  }

  /// Aligns or distributes the selected nodes; connectors follow automatically.
  public static func align(_ d: inout Diagram, ids: Set<String>, _ a: Alignment) {
    let sel = d.nodes.indices.filter { ids.contains(d.nodes[$0].id) }
    guard sel.count > 1 else { return }
    let frames = sel.map { d.nodes[$0].frame }
    switch a {
    case .left:
      let x = frames.map(\.minX).min()!
      sel.forEach { d.nodes[$0].frame.origin.x = x }
    case .right:
      let x = frames.map(\.maxX).max()!
      sel.forEach { d.nodes[$0].frame.origin.x = x - d.nodes[$0].frame.width }
    case .centerX:
      let x = frames.map(\.midX).reduce(0, +) / CGFloat(frames.count)
      sel.forEach { d.nodes[$0].frame.origin.x = x - d.nodes[$0].frame.width / 2 }
    case .top:
      let y = frames.map(\.minY).min()!
      sel.forEach { d.nodes[$0].frame.origin.y = y }
    case .bottom:
      let y = frames.map(\.maxY).max()!
      sel.forEach { d.nodes[$0].frame.origin.y = y - d.nodes[$0].frame.height }
    case .centerY:
      let y = frames.map(\.midY).reduce(0, +) / CGFloat(frames.count)
      sel.forEach { d.nodes[$0].frame.origin.y = y - d.nodes[$0].frame.height / 2 }
    case .distributeH, .distributeV:
      let horizontal = a == .distributeH
      let order = sel.sorted {
        horizontal
          ? d.nodes[$0].frame.midX < d.nodes[$1].frame.midX
          : d.nodes[$0].frame.midY < d.nodes[$1].frame.midY
      }
      guard let first = order.first, let last = order.last, order.count > 2 else { return }
      let start = horizontal ? d.nodes[first].frame.midX : d.nodes[first].frame.midY
      let end = horizontal ? d.nodes[last].frame.midX : d.nodes[last].frame.midY
      let step = (end - start) / CGFloat(order.count - 1)
      for (k, i) in order.enumerated() {
        if horizontal {
          d.nodes[i].frame.origin.x = start + step * CGFloat(k) - d.nodes[i].frame.width / 2
        } else {
          d.nodes[i].frame.origin.y = start + step * CGFloat(k) - d.nodes[i].frame.height / 2
        }
      }
    }
  }

  /// Pairs of nodes whose frames overlap (shown as a warning).
  public static func overlaps(_ d: Diagram) -> [(String, String)] {
    var out: [(String, String)] = []
    for i in d.nodes.indices {
      for j in d.nodes.indices where j > i && d.nodes[i].frame.intersects(d.nodes[j].frame) {
        out.append((d.nodes[i].id, d.nodes[j].id))
      }
    }
    return out
  }

  /// Copies nodes (and connectors between them) offset by `by`, with new IDs.
  public static func duplicate(_ d: inout Diagram, ids: Set<String>, by offset: CGPoint) -> Set<
    String
  > {
    var map: [String: String] = [:]
    for n in d.nodes where ids.contains(n.id) {
      var c = n
      c.id = "n-\(UUID().uuidString.prefix(8))"
      c.frame = c.frame.offsetBy(dx: offset.x, dy: offset.y)
      map[n.id] = c.id
      d.nodes.append(c)
    }
    for e in d.edges where map[e.from] != nil && map[e.to] != nil {
      d.edges.append(
        DiagramEdge(
          from: map[e.from]!, to: map[e.to]!, kind: e.kind, style: e.style, label: e.label))
    }
    return Set(map.values)
  }
}

// MARK: - Templates

public enum DiagramTemplate: String, CaseIterable, Sendable {
  case microservices, eventDriven, threeTier, cqrs, flowchart

  public var title: String {
    switch self {
    case .microservices: return "Microservices"
    case .eventDriven: return "Event-driven"
    case .threeTier: return "Three-tier web app"
    case .cqrs: return "CQRS"
    case .flowchart: return "Flowchart"
    }
  }

  /// An editable diagram centred on `center` (canvas px). Every element is a
  /// normal node or connector afterwards, not a picture.
  public func build(center: CGPoint) -> Diagram {
    var d = Diagram()
    func n(_ kind: String, _ label: String, _ x: CGFloat, _ y: CGFloat) -> String {
      let c = ComponentCatalog.component(kind)
      let node = DiagramNode(
        kind: kind, label: label,
        frame: CGRect(
          x: center.x + x - c.size.width / 2, y: center.y + y - c.size.height / 2,
          width: c.size.width, height: c.size.height))
      d.nodes.append(node)
      return node.id
    }
    func e(_ a: String, _ b: String, _ k: DiagramEdge.Kind, _ label: String? = nil) {
      d.edges.append(DiagramEdge(from: a, to: b, kind: k, label: label))
    }
    switch self {
    case .microservices:
      let web = n("web_app", "Web App", -420, 0)
      let lb = n("load_balancer", "Load Balancer", -200, 0)
      let gw = n("api_gateway", "API Gateway", 0, 0)
      let auth = n("auth_service", "Auth Service", 220, -170)
      let orders = n("microservice", "Orders Service", 220, 0)
      let pay = n("microservice", "Payments Service", 220, 170)
      let q = n("kafka", "order-events", 460, 85)
      let db = n("postgres", "Orders DB", 460, -60)
      let cache = n("redis", "Session Cache", 460, -210)
      e(web, lb, .http)
      e(lb, gw, .http)
      e(gw, auth, .http)
      e(gw, orders, .http)
      e(gw, pay, .grpc)
      e(orders, db, .database)
      e(orders, q, .event, "OrderPlaced")
      e(q, pay, .event, "consume")
      e(auth, cache, .database, "tokens")
    case .eventDriven:
      let prod = n("microservice", "Producer", -300, 0)
      let bus = n("event_bus", "Event Bus", 0, 0)
      let c1 = n("worker", "Billing Consumer", 300, -130)
      let c2 = n("worker", "Email Consumer", 300, 0)
      let c3 = n("worker", "Analytics Consumer", 300, 130)
      let wh = n("data_warehouse", "Warehouse", 560, 130)
      e(prod, bus, .event, "publish")
      e(bus, c1, .event)
      e(bus, c2, .event)
      e(bus, c3, .event)
      e(c3, wh, .dataflow)
    case .threeTier:
      let u = n("user", "User", -380, 0)
      let cdn = n("cdn", "CDN", -180, 0)
      let web = n("web_app", "Frontend", 20, 0)
      let api = n("backend_service", "API", 230, 0)
      let db = n("postgres", "Database", 440, -70)
      let cache = n("redis", "Cache", 440, 80)
      e(u, cdn, .http)
      e(cdn, web, .http)
      e(web, api, .http, "REST")
      e(api, db, .database)
      e(api, cache, .database, "get/set")
    case .cqrs:
      let ui = n("web_app", "Client", -360, 0)
      let cmd = n("backend_service", "Command API", -120, -110)
      let qry = n("backend_service", "Query API", -120, 110)
      let write = n("postgres", "Write Store", 140, -110)
      let bus = n("kafka", "Change Events", 140, 0)
      let proj = n("worker", "Projector", 380, 0)
      let read = n("elasticsearch", "Read Model", 140, 110)
      e(ui, cmd, .http, "commands")
      e(ui, qry, .http, "queries")
      e(cmd, write, .database)
      e(cmd, bus, .event)
      e(bus, proj, .event)
      e(proj, read, .dataflow)
      e(qry, read, .database)
    case .flowchart:
      let s = n("start_end", "Start", 0, -260)
      let i = n("io", "Read input", 0, -150)
      let dcs = n("decision", "Valid?", 0, -20)
      let p = n("process", "Process", -200, 110)
      let err = n("io", "Show error", 200, 110)
      let end = n("start_end", "End", 0, 240)
      e(s, i, .dataflow)
      e(i, dcs, .dataflow)
      e(dcs, p, .dataflow, "yes")
      e(dcs, err, .dataflow, "no")
      e(p, end, .dataflow)
      e(err, i, .dataflow, "retry")
    }
    return d
  }
}
