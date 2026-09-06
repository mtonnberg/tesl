//go:build windows

package childprocess

import (
	"fmt"
	"os/exec"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

func configure(command *exec.Cmd) {
	if command.SysProcAttr == nil {
		command.SysProcAttr = &syscall.SysProcAttr{}
	}
	// The child cannot spawn outside its job during the assignment interval.
	command.SysProcAttr.CreationFlags |= windows.CREATE_SUSPENDED
}

func attach(command *exec.Cmd, launcher bool) (func(), func(), error) {
	if command.Process == nil {
		return nil, nil, fmt.Errorf("child on Windows has not started")
	}
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, nil, err
	}
	fail := func(err error) (func(), func(), error) { _ = windows.CloseHandle(job); return nil, nil, err }
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if launcher {
		limits.BasicLimitInformation.LimitFlags |= windows.JOB_OBJECT_LIMIT_BREAKAWAY_OK
	}
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		return fail(err)
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(command.Process.Pid))
	if err != nil {
		return fail(err)
	}
	err = windows.AssignProcessToJobObject(job, process)
	_ = windows.CloseHandle(process)
	if err != nil {
		return fail(fmt.Errorf("assign child to Windows job: %w", err))
	}
	if err := resumeProcess(uint32(command.Process.Pid)); err != nil {
		return fail(err)
	}
	return func() { _ = windows.TerminateJobObject(job, 1) }, func() { _ = windows.CloseHandle(job) }, nil
}

var isProcessInJob = windows.NewLazySystemDLL("kernel32.dll").NewProc("IsProcessInJob")

// ConfigurePersistent requests explicit breakaway only when the immediate job
// allows it. Ordinary frontends outside an installer launcher keep their prior
// behavior, including when hosted by a non-breakaway CI/editor parent job.
func ConfigurePersistent(command *exec.Cmd) error {
	var inJob uint32
	ok, _, err := isProcessInJob.Call(uintptr(windows.CurrentProcess()), 0, uintptr(unsafe.Pointer(&inJob)))
	if ok == 0 {
		return err
	}
	if inJob == 0 {
		return nil
	}
	var limits windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	if err := windows.QueryInformationJobObject(0, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits)), nil); err != nil {
		return err
	}
	if limits.BasicLimitInformation.LimitFlags&windows.JOB_OBJECT_LIMIT_BREAKAWAY_OK != 0 {
		if command.SysProcAttr == nil {
			command.SysProcAttr = &syscall.SysProcAttr{}
		}
		command.SysProcAttr.CreationFlags |= windows.CREATE_BREAKAWAY_FROM_JOB
	}
	return nil
}

func resumeProcess(pid uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer func() { _ = windows.CloseHandle(snapshot) }()
	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	for err := windows.Thread32First(snapshot, &entry); err == nil; err = windows.Thread32Next(snapshot, &entry) {
		if entry.OwnerProcessID != pid {
			continue
		}
		thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
		if err != nil {
			return err
		}
		_, err = windows.ResumeThread(thread)
		_ = windows.CloseHandle(thread)
		return err
	}
	return fmt.Errorf("child %d on Windows has no initial thread", pid)
}
