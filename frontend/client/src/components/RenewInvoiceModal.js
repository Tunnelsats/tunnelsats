import React from "react";
import { useState, useRef } from "react";
import { QRCodeCanvas } from "qrcode.react";
import {
  Modal,
  Button,
  Spinner,
  Overlay,
  Tooltip,
  Collapse,
  Alert,
} from "react-bootstrap";
import success from "../media/ok-128.png";

function RenewInvoiceModal(props) {
  const [showTooltip, setShowTooltip] = useState(false);
  const [openCollapse, setOpen] = useState(true);
  const target = useRef(null);

  const renderTooltip = (show) => {
    setShowTooltip(show);
    setTimeout(() => setShowTooltip(false), [1000]);
  };

  if (!props.show) {
    return null;
  }

  if (props.value === (undefined || null)) {
    return (
      <div>
        <Modal show={props.show} onHide={props.handleClose} centered>
          <Modal.Header closeButton>
            <Modal.Title>Something went wrong</Modal.Title>
          </Modal.Header>
          <Modal.Body>
            Could not receive a valid invoice. Try again later!
          </Modal.Body>
          <Modal.Footer>
            <Button variant="outline-warning" onClick={props.handleClose}>
              Close
            </Button>
          </Modal.Footer>
        </Modal>
      </div>
    );
  }

  return (
    <div>
      <Modal
        show={props.show}
        onHide={props.handleClose}
        backdrop="static"
        keyboard={false}
        id="main_modal"
        centered
      >
        <Modal.Header closeButton>
          {props.isConfigModal ? (
            <Modal.Title>New Valid Subscription Date</Modal.Title>
          ) : (
            <Modal.Title>Scan or copy invoice</Modal.Title>
          )}
        </Modal.Header>

        <Modal.Body>
          <Alert show={props.showPaymentAlert} variant="warning">
            Payment successful!
          </Alert>
          {props.showSpinner ? (
            <Spinner animation="border" />
          ) : (
            <div>
              {props.isConfigModal ? (
                <img src={success} alt="" />
              ) : (
                <a href={"lightning:" + props.value}>
                  <QRCodeCanvas value={props.value} size={256} />
                </a>
              )}
            </div>
          )}

          <hr />
          <br />

          {props.isConfigModal ? (
            <div>
              <p>
                Your new valid subscription date is shown below.<br></br>
                Thanks for your continued support and appreciation! 🧡
              </p>
              <p id="expirydate">
                Make sure to note down your new valid date before closing!
              </p>
            </div>
          ) : (
            <p>
              Please copy the LNURL or
              <br />
              scan QR code using a lightning wallet such as
              <br />
              <a
                href="https://blixtwallet.github.io"
                target="_blank"
                rel="noreferrer"
              >
                Blixt Wallet
              </a>
              ,{" "}
              <a
                href="https://phoenix.acinq.co"
                target="_blank"
                rel="noreferrer"
              >
                Phoenix
              </a>
              ,{" "}
              <a href="https://muun.com" target="_blank" rel="noreferrer">
                Muun
              </a>
              ,{" "}
              <a
                href="https://breez.technology"
                target="_blank"
                rel="noreferrer"
              >
                Breez
              </a>{" "}
              or{" "}
              <a href="https://bluewallet.io" target="_blank" rel="noreferrer">
                BlueWallet
              </a>
              .
            </p>
          )}
          <Collapse in={openCollapse}>
            <div id="example-collapse-text">
              {props.showSpinner ? null : (
                <div id="invoicestringrenew" className="container">
                  {props.value}
                </div>
              )}
            </div>
          </Collapse>
        </Modal.Body>
        <hr />
        <Modal.Footer>
          {props.isConfigModal ? null : (
            <Button variant="outline-secondary" onClick={props.showNewInvoice}>
              Get New Invoice
            </Button>
          )}

          {/*Render Show Config or Show PR button  */}
          {/*
          {props.isConfigModal ? null : (
            <Button
              variant="outline-warning"
              onClick={() => setOpen(!openCollapse)}
              aria-controls="example-collapse-text"
              aria-expanded={!openCollapse}
            >
              {!openCollapse ? "Show Invoice" : "Hide Invoice"}
            </Button>
          )}
          */}

          {/*Render Copy Invoice or Download button  */}
            {props.isConfigModal ? null : (
              <Button
                variant="outline-warning"
                ref={target}
                onClick={() => {
                  navigator.clipboard.writeText(props.value);
                  renderTooltip(!showTooltip);
                }}
              >
                Copy Invoice
              </Button>
            )}
            {props.isConfigModal ? (
              <Button variant="outline-warning" onClick={props.handleClose}>
                Close
              </Button>
            ) : (
              <a href={"lightning:" + props.value}>
                <Button className="walletbutton" variant="outline-warning">
                  Open in Wallet
                </Button>
              </a>
            )}

            <Overlay
              target={target.current}
              transition={true}
              show={showTooltip}
              placement="top"
            >
              {(propsTooltip) => (
                <Tooltip id="copied-tooltip" {...propsTooltip}>
                  Copied!
                </Tooltip>
              )}
            </Overlay>
        </Modal.Footer>
      </Modal>
    </div>
  );
}

export default RenewInvoiceModal;
