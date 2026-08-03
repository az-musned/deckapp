# Connecting Bitfocus Companion

DeckApp connects to Companion only over the home LAN or a private VPN. Do not expose Companion with router port forwarding.

## On the Companion PC

1. Open Companion’s web interface.
2. In Companion settings, enable the HTTP remote-control API if it is disabled.
3. Note the PC’s private address and Companion web port. A typical address looks like `http://192.168.1.50:8000`, but use the port shown by your Companion installation.
4. If Windows Firewall prompts you, allow Companion only on **Private networks**. Do not enable it for public networks.
5. Make sure the iPhone or iPad is on the same LAN, or connected to the same private VPN/Tailscale network.

## In DeckApp

1. Open **Settings → Bitfocus Companion**.
2. Enter the PC address.
3. Tap **Connect and Test**.

## Test a Companion button

After connecting, choose the button’s page, row, and column in **Companion Button Test**. Page numbers start at 1; row and column numbers start at 0. DeckApp always shows a confirmation before sending the test press.

After a test is accepted, choose **Assign Tested Button** and save the location as **Launch Game** or **Sleep PC**. The corresponding dashboard button will then send that Companion location. Sleep PC always requires confirmation.

DeckApp accepts RFC 1918 LAN addresses, `.local` names, IPv6 private/link-local addresses, Tailscale `100.64.0.0/10` addresses, and Tailscale `.ts.net` names. Arbitrary public hosts are rejected.

Button actions use Companion’s current location API:

`POST /api/location/<page>/<row>/<column>/press`

An accepted HTTP response confirms only that Companion received the request. It does not prove the downstream PC action completed; completion must be confirmed separately where possible.
