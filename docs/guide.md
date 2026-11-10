# Using MIDI Router

## Make a connection

Connect your MIDI devices to the Mac and open MIDI Router. Drag an input connector onto an output connector. You can also click the connectors in sequence or choose **New Route**. Click the selected input again to cancel a pending connection. Connection hints appear while the setup has no routes and return if you remove the last route.

Connect one input to several outputs to layer instruments. Connect several inputs to one output to combine controllers. MIDI Router does not synthesize or route audio; choose the receiving instrument's audio output separately.

Click a cable, its label or a row in Terminal to open its settings. **AUTO** preserves the incoming MIDI channel. Selecting a channel sends channel messages on that channel. **Transpose** shifts notes by semitones. Notes outside the supported pitch range are not sent.

Settings appear beside the selected connection without resizing or scrolling the workspace. Choices apply immediately; text changes apply when editing finishes. New routes require **Create**. Undo restores the previous settings.

**Delete** removes the selected route when the patchbay or route list has focus. In a text field, Delete edits text instead. **All Notes Off** releases notes, sustain and per-note state owned by the router without resetting unrelated hardware.

## Route channels separately

Open a device's editor and add **Port Slots**. An input slot selects a MIDI channel; an output slot forces its assigned channel. The device's main connector becomes **CH OTHER**, covering channels not assigned to slots.

Clock, transport and other channel-less messages are forwarded once per destination rather than multiplied by channel slots. Within MIDI 2.0 traffic, channel selection and rewriting preserve the UMP group.

## Connect music apps

Choose **MIDI Router In** as an output in the sending app. Messages sent there enter the router. Choose **MIDI Router Out** as an input in the receiving app to receive messages routed to that virtual output.

Avoid sending an app's output back to its own input through the router unless you intend to create a feedback loop.

For Bluetooth devices, choose **Bluetooth MIDI** to open macOS's pairing window. Pairing is managed by the system and is not automatic.

## Save and recall a setup

On **Presets**, choose **Save Current Setup**. A preset includes routes, port slots, device aliases, visibility and layout. Recall it from the preset list or the preset selector.

To switch from a controller, assign a Program Change value from 0–127 and enable that input under **Program Change Sources**. Some controllers display the same values as 1–128. Program assignments must be unique. A matching, allowed message recalls the preset and is consumed; unmatched or disallowed messages continue through the routes.

Route changes and preset recall release notes and sustain owned by the previous setup.

## Manage devices and views

Use **Devices** to rename, reorder, hide or rebind ports. Names and layout changes are local to MIDI Router. Hiding a device does not disable its routes.

Saved devices that are absent at launch stay hidden. A device that disconnects while the app is running remains visible for 30 seconds, then disappears without losing its configuration. Enable **Show Offline Devices** to inspect or rebind it. Reconnection restores its visibility.

Studio, Terminal, Desktop and Glass show the same routes. Desktop lets you move device panels. Terminal provides a list alternative to the patchbay. The **View** menu adjusts text size; appearance follows macOS.

Dropdown menus support arrow navigation, Return, typeahead, Escape and outside-click dismissal. The macOS menu bar, file dialogs and Bluetooth window remain native system interfaces.

## Check MIDI activity

A source displays **Receiving** when MIDI reaches the Mac, even if no route exists. This does not confirm that a destination is producing sound.

**Monitor** shows received and routed messages, source and destination, group, channel, timestamp and message data. MIDI 2.0 messages include their full Universal MIDI Packet words. Transfer warnings appear separately from engine faults and are included when copying the log.

The monitor starts paused and does not accumulate event history until you turn off **Pause Display**. Pause, Clear and search affect only the display. The monitor keeps a bounded history without dropping routed events. If the input queue overflows, the affected input is suspended and its owned notes are released. **Resume Suspended Inputs** is available in the Routing menu.

**Demo Mode** generates messages between simulated devices without sending them to hardware. Leaving Demo Mode restores the previous setup. The demo does not produce audio.

## Sessions and quitting

The current session saves automatically in Application Support. Use **Open Session** and **Save Session As** to keep separate session files.

If a saved session cannot be read, the app preserves it and disables automatic saving. Use **Save As** to choose a recovery file rather than overwrite the original.

Closing the window leaves routing active. Quit the application to stop routing and release its owned notes and sustain.

See [protocol support](protocol-support.md) for MIDI compatibility details and limits.
