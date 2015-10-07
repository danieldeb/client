package libkbfs

import (
	"errors"
	"syscall"

	"bazil.org/fuse"
	"github.com/keybase/client/go/libkb"
	keybase1 "github.com/keybase/client/go/protocol"
	"github.com/keybase/go-framed-msgpack-rpc"
)

const (
	// StatusCodeBServerError is the error code for a generic block server error.
	StatusCodeBServerError = 2700
	// StatusCodeBServerErrorBadRequest is the error code for a generic client error.
	StatusCodeBServerErrorBadRequest = 2701
	// StatusCodeBServerErrorUnauthorized is the error code for when the session has not been validated
	StatusCodeBServerErrorUnauthorized = 2702
	// StatusCodeBServerErrorOverQuota is the error code for when the user has exceeded his quota
	StatusCodeBServerErrorOverQuota = 2703
	// StatusCodeBServerErrorBlockNonExistent is the error code for when bserver cannot find a block
	StatusCodeBServerErrorBlockNonExistent = 2704
	// StatusCodeBServerErrorThrottle is the error code to indicate the client should initiate backoff.
	StatusCodeBServerErrorThrottle = 2707
)

// BServerError is a generic bserver-side error.
type BServerError struct {
	Msg string
}

// ToStatus implements the ExportableError interface for BServerError.
func (e BServerError) ToStatus() (s keybase1.Status) {
	s.Code = StatusCodeBServerError
	s.Name = "SERVER_ERROR"
	s.Desc = e.Msg
	return
}

// Error implements the Error interface for BServerError.
func (e BServerError) Error() string {
	return e.Msg
}

// BServerErrorBadRequest is a generic client-side error.
type BServerErrorBadRequest struct {
	Msg string
}

// ToStatus implements the ExportableError interface for BServerError.
func (e BServerErrorBadRequest) ToStatus() (s keybase1.Status) {
	s.Code = StatusCodeBServerErrorBadRequest
	s.Name = "BAD_REQUEST"
	s.Desc = e.Msg
	return
}

// Error implements the Error interface for BServerError.
func (e BServerErrorBadRequest) Error() string {
	if e.Msg == "" {
		return "BServer: bad client request"
	}
	return e.Msg
}

// BServerErrorUnauthorized is a generic client-side error.
type BServerErrorUnauthorized struct {
	Msg string
}

// ToStatus implements the ExportableError interface for BServerErrorUnauthorized.
func (e BServerErrorUnauthorized) ToStatus() (s keybase1.Status) {
	s.Code = StatusCodeBServerErrorUnauthorized
	s.Name = "SESSION_UNAUTHORIZED"
	s.Desc = e.Msg
	return
}

// Error implements the Error interface for BServerErrorUnauthorized.
func (e BServerErrorUnauthorized) Error() string {
	if e.Msg == "" {
		return "BServer: session not validated"
	}
	return e.Msg
}

// Errno implements the fuse.ErrorNumber interface for BServerErrorUnauthorized.
func (e BServerErrorUnauthorized) Errno() fuse.Errno {
	return fuse.Errno(syscall.EACCES)
}

// BServerErrorOverQuota is a generic client-side error.
type BServerErrorOverQuota struct {
	Msg string
}

// ToStatus implements the ExportableError interface for BServerErrorOverQuota.
func (e BServerErrorOverQuota) ToStatus() (s keybase1.Status) {
	s.Code = StatusCodeBServerErrorOverQuota
	s.Name = "QUOTA_EXCEEDED"
	s.Desc = e.Msg
	return
}

// Error implements the Error interface for BServerErrorOverQuota.
func (e BServerErrorOverQuota) Error() string {
	if e.Msg == "" {
		return "BServer: user has exceeded quota"
	}
	return e.Msg
}

//BServerErrorBlockNonExistent is an exportable error from bserver
type BServerErrorBlockNonExistent struct {
	Msg string
}

// ToStatus implements the ExportableError interface for BServerErrorBlockNonExistent
func (e BServerErrorBlockNonExistent) ToStatus() (s keybase1.Status) {
	s.Code = StatusCodeBServerErrorBlockNonExistent
	s.Name = "BLOCK_NONEXISTENT"
	s.Desc = e.Msg
	return
}

// BServerErrorThrottle is returned when the server wants the client to backoff.
type BServerErrorThrottle struct {
	Msg string
}

// Error implements the Error interface for BServerErrorThrottle.
func (e BServerErrorThrottle) Error() string {
	return e.Msg
}

// ToStatus implements the ExportableError interface for BServerErrorThrottle.
func (e BServerErrorThrottle) ToStatus() (s keybase1.Status) {
	s.Code = StatusCodeBServerErrorThrottle
	s.Name = "THROTTLE"
	s.Desc = e.Msg
	return
}

// Error implements the Error interface for BServerErrorBlockNonExistent
func (e BServerErrorBlockNonExistent) Error() string {
	if e.Msg == "" {
		return "BServer: non-existent block"
	}
	return e.Msg
}

type bServerErrorUnwrapper struct{}

var _ rpc.ErrorUnwrapper = bServerErrorUnwrapper{}

func (eu bServerErrorUnwrapper) MakeArg() interface{} {
	return &keybase1.Status{}
}

func (eu bServerErrorUnwrapper) UnwrapError(arg interface{}) (appError error, dispatchError error) {
	s, ok := arg.(*keybase1.Status)
	if !ok {
		return nil, errors.New("Error converting arg to keybase1.Status object in bServerErrorUnwrapper.UnwrapError")
	}

	if s == nil || s.Code == 0 {
		return nil, nil
	}

	switch s.Code {
	case StatusCodeBServerError:
		appError = BServerError{Msg: s.Desc}
		break
	case StatusCodeBServerErrorBadRequest:
		appError = BServerErrorBadRequest{Msg: s.Desc}
		break
	case StatusCodeBServerErrorUnauthorized:
		appError = BServerErrorUnauthorized{Msg: s.Desc}
		break
	case StatusCodeBServerErrorOverQuota:
		appError = BServerErrorOverQuota{Msg: s.Desc}
		break
	case StatusCodeBServerErrorBlockNonExistent:
		appError = BServerErrorBlockNonExistent{Msg: s.Desc}
		break
	case StatusCodeBServerErrorThrottle:
		appError = BServerErrorThrottle{Msg: s.Desc}
		break
	default:
		ase := libkb.AppStatusError{
			Code:   s.Code,
			Name:   s.Name,
			Desc:   s.Desc,
			Fields: make(map[string]string),
		}
		for _, f := range s.Fields {
			ase.Fields[f.Key] = f.Value
		}
		appError = ase
	}

	return appError, nil
}
