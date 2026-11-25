# ERG TV

A personal indoor cycling app for Apple silicon Macs running macOS 26 or later. It displays live ride metrics and controls the target power of a compatible Bluetooth trainer while you watch video.

## Build and try it

1. With Xcode Command Line Tools and Swift 6.2 or later, open Terminal in this project folder and build the app.

   ```sh
   ./scripts/build-app.sh
   ```

2. Open **ERG TV** in the **outputs** folder for a real ride. To explore with simulated readings, launch the demo instead.

   ```sh
   open -n 'outputs/ERG TV.app' --args --demo
   ```

## First ride checks

1. Wake your trainer and put on your heart-rate strap. Close any other app controlling the trainer. Allow Bluetooth when macOS asks. If you previously declined, enable ERG TV under **System Settings → Privacy & Security → Bluetooth**. Open **Devices** from the ride menu to check what’s connected.
2. Sit on the bike and choose a comfortably low fixed power target in **Workout setup**. Pedal easily through the first target change at three minutes. Check that the displayed target changes and you feel the trainer respond. Check that heart rate comes from your strap and updates as you ride.
3. At easy effort, test a trainer disconnect and reconnect. Check that the app reports the interruption, shows when trainer control is uncertain and waits for you to resume. Resume at easy effort, then choose **End ride** and confirm to send the trainer a stop command. If the connection drops, the app may be unable to confirm that the trainer stopped.

## Video

Choose YouTube, Plex or BBC iPlayer from the bottom-right menu. Services open **In app** by default. If sign-in or playback fails, select **Safari** for that service in **Video settings**. Check sign-in and playback for each service you use before relying on it during a ride.

Once you choose a service, ERG TV remembers it for the next time you open the app. Turn off **Reopen last service on launch** in **Video settings** to start with an empty player.

To enlarge ERG TV on the current desktop, hover over the green window button and choose **Fill** under **Fill & Arrange**. In YouTube, **Theatre mode** enlarges the player within the page. A streaming player’s own full-screen control can move video to a separate desktop and hide the ride metrics.

Trainer control, live heart-rate readings, reconnects and signed-in playback still need hands-on verification. Garmin integration is deferred.
