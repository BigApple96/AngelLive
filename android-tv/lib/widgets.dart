import 'package:flutter/material.dart';
import 'data.dart';

void showError(BuildContext context, Object error) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(friendlyError(error)),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

class TvTile extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  const TvTile({
    super.key,
    required this.child,
    required this.onPressed,
    this.autofocus = false,
  });
  @override
  State<TvTile> createState() => _TvTileState();
}

class _TvTileState extends State<TvTile> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Material(
    color: focused ? const Color(0xff30314f) : const Color(0xff191c2a),
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      autofocus: widget.autofocus,
      borderRadius: BorderRadius.circular(16),
      onTap: widget.onPressed,
      onFocusChange: (v) {
        setState(() => focused = v);
        if (v) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Scrollable.ensureVisible(
                context,
                alignment: .5,
                duration: const Duration(milliseconds: 180),
              );
            }
          });
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: focused ? const Color(0xffb8b1ff) : Colors.white12,
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(14),
        child: widget.child,
      ),
    ),
  );
}

class RoomTile extends StatelessWidget {
  final Map<String, dynamic> room;
  final VoidCallback onPressed;
  const RoomTile({super.key, required this.room, required this.onPressed});
  @override
  Widget build(BuildContext context) => TvTile(
    onPressed: onPressed,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: double.infinity,
              child: string(room['roomCover']).isEmpty
                  ? const ColoredBox(
                      color: Color(0xff252b42),
                      child: Center(child: Icon(Icons.live_tv, size: 38)),
                    )
                  : Image.network(
                      string(room['roomCover']),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const Center(child: Icon(Icons.live_tv, size: 38)),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          string(room['roomTitle']).isEmpty
              ? string(room['roomId'])
              : string(room['roomTitle']),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          string(room['userName']),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white60, fontSize: 13),
        ),
      ],
    ),
  );
}

Future<String?> inputText(
  BuildContext context,
  String title, {
  String initial = '',
  String? hint,
  bool secret = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 600,
        child: TextField(
          controller: controller,
          autofocus: true,
          obscureText: secret,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
  return result;
}
