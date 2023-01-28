import React from "react";
import { ToggleButtonGroup, ToggleButton } from "react-bootstrap";

// Env Variables to have the same code base main and dev
const REACT_APP_ONE_MONTH = process.env.REACT_APP_ONE_MONTH || 3.0;
const REACT_APP_THREE_MONTHS = process.env.REACT_APP_THREE_MONTHS || 8.5;
const REACT_APP_SIX_MONTHS = process.env.REACT_APP_SIX_MONTHS || 16.0;
const REACT_APP_ONE_YEAR = process.env.REACT_APP_ONE_YEAR || 28.5;

const RuntimeSelector = (props) => {
  return (
    <div>
      <ToggleButtonGroup
        type="radio"
        name="options"
        id="runtimeselector"
        defaultValue={JSON.stringify({
          priceDollar: REACT_APP_THREE_MONTHS,
          selection: 2,
        })}
      >
        <ToggleButton
          id="tbg-radio-1"
          variant="secondary"
          value={JSON.stringify({
            priceDollar: REACT_APP_ONE_MONTH,
            selection: 1,
          })}
          onClick={props.onClick}
        >
          1 <br></br> month
        </ToggleButton>
        <ToggleButton
          id="tbg-radio-2"
          variant="secondary"
          value={JSON.stringify({
            priceDollar: REACT_APP_THREE_MONTHS,
            selection: 2,
          })}
          onClick={props.onClick}
        >
          3 <br></br> months
        </ToggleButton>
        <ToggleButton
          id="tbg-radio-3"
          variant="secondary"
          value={JSON.stringify({
            priceDollar: REACT_APP_SIX_MONTHS,
            selection: 3,
          })}
          onClick={props.onClick}
        >
          6 <br></br> months
        </ToggleButton>
        <ToggleButton
          id="tbg-radio-4"
          variant="secondary"
          value={JSON.stringify({
            priceDollar: REACT_APP_ONE_YEAR,
            selection: 4,
          })}
          onClick={props.onClick}
        >
          12 <br></br> months
        </ToggleButton>
      </ToggleButtonGroup>
    </div>
  );
};

export default RuntimeSelector;
