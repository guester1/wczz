# wczz 1.0-9

Independent WeChat 8.0.75 tweak.

- Main list filtering is implemented at `MainFrameLogicController`, not UITableView.
- Only usernames ending in `@chatroom` are eligible.
- Common groups stay in the normal list.
- The synthetic `群助手` row can be top or bottom.
- The helper uses WeChat's `MMBaseSessionTableViewCell` and session cell data when available, so group rows retain native avatar collage, unread badge, message preview, time and mute/status presentation.
- No WeChat native top-session folding is triggered, avoiding the previous `置顶聊天` row and reload/animation flicker.
- Red-envelope hooks are installed after the relevant WeChat classes become available.
