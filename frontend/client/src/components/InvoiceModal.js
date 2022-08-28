import React from 'react';
import { useState, useRef } from 'react';
import { QRCodeCanvas } from 'qrcode.react';
import { Modal, Button, Spinner, Overlay, Tooltip, Collapse, Alert } from 'react-bootstrap';
import EmailModal from './EmailModal';
import success from '../media/ok-128.png';

function InvoiceModal(props) {
  const [visibleEmailModal, setShowEmailModal] = useState(false);
  const closeEmailModal = () => setShowEmailModal(false);
  const showEmailModal = () => setShowEmailModal(true);


  const [showTooltip, setShowTooltip] = useState(false);
  const [openCollapse, setOpen] = useState(true);
  const target = useRef(null);

  //const [paymentHash, setPaymentHash] = useState(props.value);



  const renderTooltip = (show) => {
    setShowTooltip(show)
    setTimeout(() => setShowTooltip(false), [1000])
  }


  if (!props.show) {
    return (null)
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

    )
  }

  return (
    <div>
      <Modal show={props.show}
        onHide={props.handleClose}
        backdrop="static"
        keyboard={false}
        id="main_modal"
        centered
      >
        <Modal.Header closeButton>
          {props.isConfigModal ?
            <Modal.Title>Send or download wireguard config</Modal.Title> :
              props.isRenewSub ?
                <Modal.Title>New Supscription Date</Modal.Title> :
                <Modal.Title>Scan or copy invoice</Modal.Title>
          }
        </Modal.Header>

        <Modal.Body>
          <Alert show={props.showPaymentAlert} variant="warning">
            Payment successful!
          </Alert>
          {props.showSpinner ?
            <Spinner animation="border" /> :
            <div>
              {props.isConfigModal ?
                //<QRCodeCanvas value={props.value} size={256} /> :
                //<QRCodeCanvas value={props.value} size={0}/> 
                <img src={success} alt="" />
                : <a href={"lightning:" + props.value}>
                  <QRCodeCanvas value={props.value} size={256} />
                </a>
              }
            </div>
          }


          { props.isConfigModal ?
            <div>
              <p>
                WireGuard VPN config, download the config file
                or send via Email to transfer to your lightning node.
              </p>
              <p id='expirydate'>
                Valid until: {props.expiryDate.toISOString()}<br></br>
                Make sure to save your config before closing. Otherwise it is lost.
              </p>
            </div>
            :
              props.isRenewSub ? 
                <p>Your new valid subscription date is shown above. Thank you for your support and appreciation! 🧡</p>
                :
                <p>This is a lightning invoice. Pay with a wallet like <a href="https://blixtwallet.github.io" target="_blank" rel="noreferrer">Blixt Wallet</a>, <a href="https://phoenix.acinq.co/" target="_blank" rel="noreferrer">Phoenix</a>, <a href="https://muun.com/" target="_blank" rel="noreferrer">Muun</a>, <a href="https://breez.technology/" target="_blank" rel="noreferrer">Breez</a> or <a href="https://bluewallet.io/" target="_blank" rel="noreferrer">BlueWallet</a>.</p>
          }
          <Collapse in={openCollapse}>
            <div id="example-collapse-text">
              {props.showSpinner
                ? null
                : <div id="invoicestring" className="container">{props.value}</div>
              }
            </div>
          </Collapse>
        </Modal.Body>
        <Modal.Footer>

          {props.isConfigModal 
            ? <Button variant="outline-warning" onClick={() => { showEmailModal(true) }}>Send via Email</Button>
            : props.isRenewSub
              ? null
              : <Button variant="outline-secondary" onClick={props.showNewInvoice}>Get new Invoice</Button>
          }

          {/*Render Show Config or Show PR button  */}
          {props.isRenewSub
            ? <Button className="closeButton" onClick={props.handleClose}>Close</Button>
            : props.isConfigModal 
              ? <Button
                variant="outline-secondary"
                onClick={() => setOpen(!openCollapse)}
                aria-controls="example-collapse-text"
                aria-expanded={!openCollapse}
              >{!openCollapse ? 'Show Config' : 'Hide Config'}
              </Button> 
              : <Button variant="outline-warning"
                onClick={() => setOpen(!openCollapse)}
                aria-controls="example-collapse-text"
                aria-expanded={!openCollapse}
              >{!openCollapse ? 'Show Invoice' : 'Hide Invoice'}
              </Button>}

          {/*Render Copy Invoice or Download button  */}
          { props.isRenewSub 
          ? null
          : props.isConfigModal
            ? <Button variant="outline-warning" onClick={props.download}>Download as File</Button>
            : <Button variant="outline-warning" ref={target} onClick={() => { navigator.clipboard.writeText(props.value); renderTooltip(!showTooltip) }}>
              Copy Invoice</Button>
          }
          { props.isRenewSub 
          ? null
          : props.isConfigModal
            ? ""
            : <a href={"lightning:" + props.value} ><Button className="walletbutton" variant="outline-warning">Open in Wallet</Button></a>
          }


          <Overlay target={target.current} transition={true} show={showTooltip} placement="top">
            {(propsTooltip) => (<Tooltip id="copied-tooltip" {...propsTooltip}>Copied!</Tooltip>)}
          </Overlay>
        </Modal.Footer>
      </Modal>
      <EmailModal
        show={visibleEmailModal}
        handleClose={closeEmailModal}
        sendEmail={(data) => props.sendEmail(data)}
      />
    </div>
  )
}


export default InvoiceModal
