import { ToggleButtonGroup, ToggleButton } from "react-bootstrap";
const CountrySelector = (props) => {
  return (
    <div>
      <ToggleButtonGroup
        type="radio"
        name="options"
        id="countryselector"
        defaultValue={1}
      >
        <ToggleButton value={1} onClick={props.onClick} variant="secondary">
          🇪🇺 <br></br>EU
        </ToggleButton>
        <ToggleButton value={2} onClick={props.onClick} variant="secondary">
          🇺🇸 <br></br>USA
        </ToggleButton>
        <ToggleButton
          value={3}
          /*onClick={props.onClick}*/ variant="secondary"
          disabled
        >
          🇨🇦 <br></br>CAD
        </ToggleButton>
        <ToggleButton
          value={4}
          /*onClick={props.onClick}*/ variant="secondary"
          disabled
        >
          🇬🇧 <br></br>UK
        </ToggleButton>
        <ToggleButton
          value={5}
          /*onClick={props.onClick}*/ variant="secondary"
          disabled
        >
          🇸🇬 <br></br>SGP
        </ToggleButton>
      </ToggleButtonGroup>
    </div>
  );
};

export default CountrySelector;
