import React from 'react'
import { Modal, Button } from 'react-bootstrap'


const FAQModal = (props) => {

  if (!props.show) {
    return (null)
  }


  return (
    <div>

      <Modal
        id="faq_modal"
        show={props.show}
        onHide={props.handleClose}
        centered
        fullscreen={true}
      >
        <Modal.Header closeButton>
          <Modal.Title>
            FAQ
          </Modal.Title>
        </Modal.Header>
        <Modal.Body>
          <div>

            <h4>Server Status</h4>

            <Button variant="success">🇪🇺 <br></br>EU</Button>{'  '}
            <Button variant="success">🇺🇸 <br></br>USA</Button>{'  '}
            <Button variant="success">🇨🇦 <br></br>CAD</Button>{'  '}
            <Button variant="danger">🇬🇧 <br></br>UK</Button>{'  '}
            <Button variant="secondary">🇸🇬 <br></br>SGP</Button>

            <p></p>

            <h4>About</h4>
            <p>With Tunnel⚡Sats we try to bring hybrid mode to lightning node runners in an easy, guided and pre-configured way. Offering setup scripts for almost every node setup out there and chosen VPN WireGuard servers in various countries that can be rent for certain timeframes and pay anonymously via Bitcoin Lightning ⚡!</p>

            <h4>How does it work?</h4>
            <p>
              On this website you automatically generate WireGuard VPN keys via JavaScript inside of your browser. After selecting a country, click "Generate Invoice" to receive a QR code or an invoice URL which can be scanned with Bitcoin Lightning capable wallets like <a href="https://blixtwallet.github.io" target="_blank" rel="noreferrer">Blixt Wallet</a>, <a href="https://phoenix.acinq.co/" target="_blank" rel="noreferrer">Phoenix</a>, <a href="https://muun.com/" target="_blank" rel="noreferrer">Muun</a>, <a href="https://breez.technology/" target="_blank" rel="noreferrer">Breez</a> or <a href="https://bluewallet.io/" target="_blank" rel="noreferrer">BlueWallet</a> or pay by copying the invoice string. After successful payment, the website reloads and provides the WireGuard configuration file to download or send via email.
            </p>

            <h4> What services are used?</h4>
            <p>
              As payment backend we use <a href="https://legend.lnbits.com/" target="_blank" rel="noreferrer">LNBits</a> for lightning payments, to send WireGuard config files via email we use our own mailserver and to provide this frontend React and WebSockets are being imported.
              As for the VPN endpoints, we make use of our own rented virtual servers from Digital Ocean (EU), Y (SG) and Z (US) with <a href="https://github.com/Mawthuq-Software/wireguard-manager-and-api" target="_blank" rel="noreferrer">WireGuard Manager and API</a> managing the WireGuard setup and accounts safely.
            </p>

            <h4>What about data storage and privacy?</h4>
            <p>
              On the website, we don't use cookies and we only store the first half of your ip address in our webserver logs. For example the IP 1.12.123.234 would be stored as 1.12.0.0.
              On the VPN endpoints we store your WireGuard public key, preshared key, forwarded ports and total amount of bandwidth you used. While maintaining an active connection to a VPN endpoint, we have to keep your IP address in memory. We never store it on disk.
              As payments are only possible via Bitcoin Lightning, we don't know where the Satoshis comes from, we can only verify whether an invoice was paid or not.
              If you use "Send via email" feature for transfering your WireGuard configuration, the email is sent via our own mailserver.
            </p>
            <h4>What happens on expiration of the paid period?</h4>
            <p>
              You won't be able to transfer any data over the VPN connection anymore. Your VPN client may indicate it is successfully connected, though.
            </p>

            <h4>Is there a data transfer limit?</h4>
            <p>
              Currently, we offer 100GB per month which should be good enough even for bigger nodes with lots of channels.
            </p>

            <h4>Do you also offer full-service VPNs?</h4>
            <p>
              No, currently this service is focused on providing fast VPN connectivity for routing nodes on the lightning network. But if you are looking for privacy-preserving, lightning payment-enabled, full-service VPNs, we recommend to take a look at <a href="https://lnvpn.net" target="_blank" rel="noreferrer">lnvpn.net</a>.
            </p>


            <h4>Who build this?</h4>
            <p>
              From Node Runnners for Node Runners 🧡
            </p>
          </div>
        </Modal.Body>
        <Modal.Footer>
          <Button variant="outline-warning" onClick={props.handleClose}>Close</Button>
        </Modal.Footer>
      </Modal>

    </div>
  )
}

export default FAQModal
