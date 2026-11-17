import 'dart:convert';
import 'dart:typed_data';

import '../core/constants.dart';

enum MessageType {
  /// One-to-one chat text.
  text,

  /// Delivery receipt. [MeshMessage.refId] names the acknowledged message and
  /// [MeshMessage.content] holds the hop count it arrived with.
  ack,

  /// Emergency broadcast to every node.
  sos,
}

/// The unit that travels across the mesh. Field names on the wire follow the
/// spec's JSON layout; `type`, `sender_name`, `ref_id`, `lat` and `lng` are
/// additions needed for receipts, display names and SOS.
class MeshMessage {
  const MeshMessage({
    required this.id,
    required this.type,
    required this.senderId,
    required this.senderName,
    required this.receiverId,
    required this.timestamp,
    required this.content,
    this.hopCount = 0,
    this.maxHops = MeshConstants.defaultMaxHops,
    this.refId,
    this.lat,
    this.lng,
  });

  final String id;
  final MessageType type;
  final String senderId;
  final String senderName;
  final String receiverId;

  /// Milliseconds since epoch, set by the sender.
  final int timestamp;
  final String content;

  /// Number of relays this copy has passed through.
  final int hopCount;
  final int maxHops;
  final String? refId;
  final double? lat;
  final double? lng;

  bool get isBroadcast => receiverId == MeshConstants.broadcastId;
  bool get canRelay => hopCount < maxHops;
  bool get hasLocation => lat != null && lng != null;

  MeshMessage relayed() => MeshMessage(
        id: id,
        type: type,
        senderId: senderId,
        senderName: senderName,
        receiverId: receiverId,
        timestamp: timestamp,
        content: content,
        hopCount: hopCount + 1,
        maxHops: maxHops,
        refId: refId,
        lat: lat,
        lng: lng,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type.name,
        'sender_id': senderId,
        'sender_name': senderName,
        'receiver_id': receiverId,
        'timestamp': timestamp,
        'content': content,
        'hop_count': hopCount,
        'max_hops': maxHops,
        if (refId != null) 'ref_id': refId,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      };

  factory MeshMessage.fromJson(Map<String, Object?> json) => MeshMessage(
        id: json['id']! as String,
        type: MessageType.values.byName(json['type']! as String),
        senderId: json['sender_id']! as String,
        senderName: (json['sender_name'] as String?) ?? '',
        receiverId: json['receiver_id']! as String,
        timestamp: (json['timestamp']! as num).toInt(),
        content: (json['content'] as String?) ?? '',
        hopCount: (json['hop_count']! as num).toInt(),
        maxHops: (json['max_hops']! as num).toInt(),
        refId: json['ref_id'] as String?,
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
      );

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Returns null for anything that isn't a well-formed message, so a
  /// misbehaving peer can't crash the router.
  static MeshMessage? tryDecode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > MeshConstants.maxFrameBytes) return null;
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, Object?>) return null;
      final message = MeshMessage.fromJson(json);
      if (message.id.isEmpty || message.id.length > 128 ||
          message.senderId.isEmpty || message.senderId.length > 128 ||
          message.receiverId.isEmpty || message.receiverId.length > 128 ||
          message.senderName.length > 128 ||
          utf8.encode(message.content).length > MeshConstants.maxContentBytes ||
          message.hopCount < 0 ||
          message.maxHops < 1 ||
          message.maxHops > 16 ||
          message.hopCount > message.maxHops ||
          (message.type == MessageType.ack && message.refId == null) ||
          (message.refId?.length ?? 0) > 128 ||
          ((message.lat == null) != (message.lng == null)) ||
          (message.lat != null && (message.lat! < -90 || message.lat! > 90)) ||
          (message.lng != null && (message.lng! < -180 || message.lng! > 180))) {
        return null;
      }
      return message;
    } catch (_) {
      return null;
    }
  }
}
