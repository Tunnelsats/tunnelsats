/*

Logger for keeping track of REST API Calles and Socket.io Emits

*/


const dim = '\x1b[2m'
const undim = '\x1b[0m'

const getDate = timestamp => (timestamp !== undefined ? new Date(timestamp) : new Date()).toISOString()

const logDim = (...args) => console.log(`${getDate()} ${dim}${args.join(' ')}${undim}`)



const log = {
    logDim
}


module.exports = log