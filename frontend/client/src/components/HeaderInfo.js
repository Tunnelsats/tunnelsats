import React from "react";
import { Alert } from "react-bootstrap";

const HeaderInfo = () => {
  return (
    <div>
      <Alert variant="secondary">
        {/* <Alert.Heading>How it works:</Alert.Heading> */}
        <p>
          Tunnel⚡️Sats provides setup scripts for lightning nodes enabling
          hybrid mode through clearnet & Tor connectivity and offers paid VPN
          servers in various continents to rent for fixed periods of time. Our
          secured and lightning-only configured VPNs support port-forwarding to
          connect with other lightning nodes.
          <br></br>
          <br></br>
          <b>How Tunnel⚡️Sats works</b>
          <br></br>Select a preferred continent and period of time and pay the
          invoice via lightning to receive a WireGuard configuration file.
          Download setup script to install required components and configure
          your node setup for hybrid mode.
          <br></br>
          <br></br>For detailed installation instructions please read the
          TunnelSats{" "}
          <a
            href="https://blckbx.github.io/tunnelsats/"
            target="_blank"
            rel="noreferrer"
          >
            guide
          </a>{" "}
          and{" "}
          <a
            href="https://blckbx.github.io/tunnelsats/FAQ.html"
            target="_blank"
            rel="noreferrer"
          >
            FAQ
          </a>{" "}
          page.
        </p>
        <hr />
        <p className="mb-0">
          WireGuard keys are generated exclusively within the browser!
        </p>
      </Alert>
    </div>
  );
};

export default HeaderInfo;
