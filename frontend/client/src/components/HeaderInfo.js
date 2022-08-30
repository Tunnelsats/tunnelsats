import React from "react";
import { Alert } from "react-bootstrap";

const HeaderInfo = () => {
  return (
    <div>
      <Alert variant="secondary">
        {/* <Alert.Heading>How it works:</Alert.Heading> */}
        <p>
          Tunnel⚡️Sats provides scripts for lightning nodes enabling hybrid
          mode (clearnet & Tor connectivity) and offers paid VPN servers on
          various continents for rent for fixed terms. Our secured and
          lightning-only configured VPNs support port-forwarding to connect with
          other lightning nodes.
          <br></br>
          <br></br>
          <b>How Tunnel⚡️Sats works</b>
          <br></br>Select a preferred continent and period of time and pay the
          invoice via lightning to receive a WireGuard configuration file.
          Please follow the detailed installation instructions described on the
          TunnelSats
          {" "}
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
            faq
          </a>{" "}
          pages.
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
