# wczz v1.0-3

Independent implementation for WeChat 8.0.75.

## Design

- Does not reuse Miyou's folding implementation.
- Only usernames ending in `@chatroom` are eligible for group folding.
- Friends and non-group sessions are never collected.
- Common groups remain in the normal session list.
- Non-common groups are represented by a single "群助手" row.
- The helper row can be placed at the top or bottom.
- Tapping it opens a list of collected groups.
- Tapping a collected group opens the original WeChat session.
- Settings are registered through WCPluginsMgr when available.
- Red-envelope detail summary is independent of the group-list implementation.

## Main-list strategy

The implementation hooks the actual `UITableViewDataSource/Delegate` methods on
`NewMainFrameViewController` exposed by the WeChat 8.0.75 headers:

- `tableView:numberOfRowsInSection:`
- `tableView:cellForRowAtIndexPath:`
- `tableView:heightForRowAtIndexPath:`
- `tableView:didSelectRowAtIndexPath:`

It deliberately does not hook `MainFrameLogicController`'s row-count/data methods.
