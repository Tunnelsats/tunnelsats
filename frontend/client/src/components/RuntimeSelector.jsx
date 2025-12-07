import { ToggleButtonGroup, ToggleButton } from "react-bootstrap";

// Env Variables to have the same code base main and dev
const VITE_ONE_MONTH = import.meta.env.VITE_ONE_MONTH || 3.0;
const VITE_THREE_MONTHS = import.meta.env.VITE_THREE_MONTHS || 8.5;
const VITE_SIX_MONTHS = import.meta.env.VITE_SIX_MONTHS || 16.0;
const VITE_ONE_YEAR = import.meta.env.VITE_ONE_YEAR || 28.5;

const RuntimeSelector = (props) => {
  return (
    <div>
      <ToggleButtonGroup
        type="radio"
        name="options"
        id="runtimeselector"
        defaultValue={JSON.stringify({
          priceDollar: VITE_THREE_MONTHS,
          selection: 2,
        })}
      >
        <ToggleButton
          id="tbg-radio-1"
          variant="secondary"
          value={JSON.stringify({
            priceDollar: VITE_ONE_MONTH,
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
            priceDollar: VITE_THREE_MONTHS,
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
            priceDollar: VITE_SIX_MONTHS,
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
            priceDollar: VITE_ONE_YEAR,
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
