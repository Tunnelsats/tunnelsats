// Env Variables to have the same code base main and dev
const REACT_APP_ONE_MONTH = process.env.REACT_APP_ONE_MONTH || 0.001;
const REACT_APP_THREE_MONTHS = process.env.REACT_APP_THREE_MONTHS || 0.002;
const REACT_APP_SIX_MONTHS = process.env.REACT_APP_SIX_MONTHS || 0.003;
const REACT_APP_ONE_YEAR = process.env.REACT_APP_ONE_YEAR || 0.004;

const getTimeStamp = (selectedValue, offset) => {
  let date = new Date();
  if (offset && Date.now() < Date.parse(offset)) {
    let unixtime = Date.parse(offset);
    date = new Date(unixtime);
  }

  if (selectedValue == REACT_APP_ONE_MONTH) {
    date = addMonths(date, 1);
    return date;
  }
  if (selectedValue == REACT_APP_THREE_MONTHS) {
    date = addMonths(date, 3);
    return date;
  }
  if (selectedValue == REACT_APP_SIX_MONTHS) {
    date = addMonths(date, 6);
    return date;
  }
  if (selectedValue == REACT_APP_ONE_YEAR) {
    date = addMonths(date, 12);
    return date;
  }

  function addMonths(date = new Date(), months) {
    var d = date.getDate();
    date.setMonth(date.getMonth() + +months);
    if (date.getDate() !== d) {
      date.setDate(0);
    }
    return date;
  }
};

export { getTimeStamp };
