import 'package:flutter/material.dart';
import '../models/time_entity.dart';

/// 日历事件确认对话框（原闹钟对话框，已改为写入系统日历）
class AlarmDialog extends StatefulWidget {
  final TimeEntity timeEntity;
  final String diaryContent;

  const AlarmDialog({
    super.key,
    required this.timeEntity,
    required this.diaryContent,
  });

  @override
  State<AlarmDialog> createState() => _AlarmDialogState();

  /// 显示对话框
  static Future<({bool confirmed, bool enableAlarm})?> show(
    BuildContext context,
    TimeEntity timeEntity,
    String diaryContent,
  ) {
    return showModalBottomSheet<({bool confirmed, bool enableAlarm})?>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => AlarmDialog(
        timeEntity: timeEntity,
        diaryContent: diaryContent,
      ),
    );
  }
}

class _AlarmDialogState extends State<AlarmDialog> {
  bool _enableAlarm = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加日历提醒'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '提醒时间：',
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '响铃闹钟',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                  Switch(
                    value: _enableAlarm,
                    onChanged: (v) => setState(() => _enableAlarm = v),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.timeEntity.text,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _enableAlarm == true
                ? '将写入系统日历，到点自动响铃提醒'
                : '将写入系统日历，到点不会响铃（仅日历事件）',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
          const SizedBox(height: 12),
          Text(
            '提醒内容：',
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
          const SizedBox(height: 4),
          Text(
            widget.diaryContent,
            style: const TextStyle(fontSize: 14),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop((confirmed: true, enableAlarm: _enableAlarm)),
          child: const Text('添加到日历'),
        ),
      ],
    );
  }
}
